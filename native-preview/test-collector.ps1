# SPDX-License-Identifier: Apache-2.0
$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem
$root=Split-Path $PSScriptRoot -Parent
$out=Join-Path $root ('build/preview/collector-tests-'+(Get-Date -Format 'yyyyMMdd-HHmmss-fff'))
New-Item -ItemType Directory -Path $out | Out-Null
$results=@()
foreach($mode in @('default','pages')){
 $dir=Join-Path $out $mode;New-Item -ItemType Directory -Path $dir | Out-Null
 Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'collect-results.ps1') -Destination $dir
 foreach($number in 1,2,3){
  $run=Join-Path $dir ('bridge-20261014-00000'+$number)
  New-Item -ItemType Directory -Path (Join-Path $run 'job-000001') | Out-Null
  Set-Content -LiteralPath (Join-Path $run 'session-result.json') '{"state":"CLEAN_SHUTDOWN","completed_jobs":1}'
  Set-Content -LiteralPath (Join-Path $run 'framework.log') 'Test framework log'
  Set-Content -LiteralPath (Join-Path $run 'job-000001/bridge-result.json') '{"success":true}'
  Set-Content -LiteralPath (Join-Path $run 'job-000001/page-01.pgm') 'Private page payload'
 }
 Set-Content -LiteralPath (Join-Path $dir 'SESSION-ACTIVE-recovered-test.lock') 'Preserve this lock'
 Set-Content -LiteralPath (Join-Path $dir 'recovery-test.json') '{"automatic_replay":false}'
 Set-Content -LiteralPath (Join-Path $dir 'control-cancel-test.json') '{"outcome":"CancelAccepted"}'
 Set-Content -LiteralPath (Join-Path $dir 'queue-owned.json') '{"state":"Owned","queue":{"Name":"Synthetic test queue"}}'
 Set-Content -LiteralPath (Join-Path $dir 'queue-setup-test-result.json') '{"outcome":"ExistingNotOwned"}'
 Set-Content -LiteralPath (Join-Path $dir 'recovery-backup-test.zip') 'Backup bytes'
 $before=@{};Get-ChildItem -LiteralPath $dir -Recurse -File | ForEach-Object {$before[$_.FullName]=(Get-FileHash -LiteralPath $_.FullName).Hash}
 $args=@('-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $dir 'collect-results.ps1'))
 if($mode -eq 'pages'){$args+='-IncludePageData'}
 & powershell.exe @args
 if($LASTEXITCODE){throw 'Collector failed'}
 foreach($path in $before.Keys){if((Get-FileHash -LiteralPath $path).Hash -ne $before[$path]){throw 'Collector changed an original file'}}
 $zip=@(Get-ChildItem -LiteralPath $dir -File -Filter 'preview-results-*.zip')
 if($zip.Count -ne 1){throw 'Expected one collection'}
 $extract=Join-Path $dir 'extracted';[IO.Compression.ZipFile]::ExtractToDirectory($zip[0].FullName,$extract)
 $summary=Get-Content -LiteralPath (Join-Path $extract 'SUMMARY.json') -Raw | ConvertFrom-Json
 if($summary.sessions.Count -ne 3 -or $summary.latest_sessions.Count -ne 2){throw 'Session history incomplete'}
 $pages=@(Get-ChildItem -LiteralPath $extract -Recurse -Filter '*.pgm')
 if($pages.Count -ne $(if($mode -eq 'pages'){2}else{0})){throw 'Wrong page-data selection'}
 if(@(Get-ChildItem -LiteralPath $extract -Recurse -Filter 'framework.log').Count -ne 2){throw 'Wrong recent log count'}
 if(@(Get-ChildItem -LiteralPath $extract -Recurse -Filter 'bridge-result.json').Count -ne 3){throw 'Historical reports missing'}
 if(Test-Path -LiteralPath (Join-Path $extract 'recovery-backup-test.zip')){throw 'Nested backup copied'}
 foreach($setupFile in @('queue-owned.json','queue-setup-test-result.json')){if(-not (Test-Path -LiteralPath (Join-Path $extract $setupFile))){throw 'Queue setup report missing'}}
 if($summary.recovery_backups[0].sha256 -ne (Get-FileHash -LiteralPath (Join-Path $dir 'recovery-backup-test.zip')).Hash){throw 'Wrong backup hash'}
 $manifest=Get-Content -LiteralPath (Join-Path $extract 'MANIFEST.json') -Raw | ConvertFrom-Json
 foreach($entry in $manifest.files){if((Get-FileHash -LiteralPath (Join-Path $extract $entry.path)).Hash -ne $entry.sha256){throw 'Manifest mismatch'}}
 $results+=@{name=$mode;result='PASS';collected_files=$manifest.files.Count;page_files=$pages.Count}
}
@{result='PASS';tests=$results;collector_sha256=(Get-FileHash -LiteralPath (Join-Path $PSScriptRoot 'collect-results.ps1')).Hash;scope='Isolated synthetic files only; no queue or printer access'} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $out 'results.json')
Write-Host $out
