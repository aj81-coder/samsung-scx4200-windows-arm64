# SPDX-License-Identifier: Apache-2.0
param([switch]$IncludePageData)
$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem
$stamp=Get-Date -Format 'yyyyMMdd-HHmmss-fff'
$zip=Join-Path $PSScriptRoot ('preview-results-'+$stamp+'.zip')
$stage=Join-Path $PSScriptRoot ('collection-'+$stamp)
if(Test-Path -LiteralPath $stage){throw 'Collection directory already exists.'}
$runs=@(Get-ChildItem -LiteralPath $PSScriptRoot -Directory | Where-Object Name -match '^bridge-\d' | Sort-Object Name)
if(-not $runs.Count){throw 'No bridge results found in this folder.'}
$recent=@($runs | Select-Object -Last 2 | Select-Object -ExpandProperty Name)
$sourceFiles=New-Object Collections.Generic.List[IO.FileInfo]
$sessions=@();$backups=@();$missing=@()
function Get-EvidenceFiles([string]$Directory){
 foreach($entry in Get-ChildItem -LiteralPath $Directory){
  if($entry.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Linked evidence files or directories are not supported.'}
  if($entry.PSIsContainer){Get-EvidenceFiles $entry.FullName}else{$entry}
 }
}
foreach($run in $runs){
 if($run.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Linked session directories are not supported.'}
 $session=Join-Path $run.FullName 'session-result.json'
 $value=$null
 if(Test-Path -LiteralPath $session){try{$value=Get-Content -LiteralPath $session -Raw | ConvertFrom-Json}catch{$missing+=($run.Name+': unreadable session report')}}else{$missing+=($run.Name+': no session report')}
 $sessions+=@{run=$run.Name;report=$value;recent_full_logs=($run.Name -in $recent)}
 foreach($file in Get-EvidenceFiles $run.FullName){
  # Never follow filesystem links into unrelated folders.
  if($file.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Linked evidence file is not supported.'}
  if($file.Extension -eq '.json' -or ($run.Name -in $recent -and ($file.Name -eq 'framework.log' -or $IncludePageData))){$sourceFiles.Add($file)}
 }
}
foreach($pattern in @('startup-check-*.json','control-*.json','control-*.jsonl','recovery-*.json','queue-owned.json','queue-setup-*.json','SESSION-ACTIVE*.lock')){
 foreach($file in Get-ChildItem -LiteralPath $PSScriptRoot -File -Filter $pattern){
  if($file.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Linked report is not supported.'}
  $sourceFiles.Add($file)
 }
}
foreach($file in Get-ChildItem -LiteralPath $PSScriptRoot -File -Filter 'recovery-backup-*.zip'){
 if($file.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Linked backup is not supported.'}
 $backups+=@{name=$file.Name;bytes=$file.Length;sha256=(Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash}
}
New-Item -ItemType Directory -Path $stage | Out-Null
$manifest=@()
$prefix=$PSScriptRoot.TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar
foreach($file in $sourceFiles | Sort-Object FullName -Unique){
 if(-not $file.FullName.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)){throw 'Evidence path is outside this folder.'}
 $relative=$file.FullName.Substring($prefix.Length)
 $destination=Join-Path $stage $relative
 New-Item -ItemType Directory -Path (Split-Path $destination -Parent) -Force | Out-Null
 Copy-Item -LiteralPath $file.FullName -Destination $destination
 $copy=Get-Item -LiteralPath $destination
 $manifest+=@{path=$relative;bytes=$copy.Length;sha256=(Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash}
}
$summary=[ordered]@{schema_version=1;collected_utc=[DateTime]::UtcNow.ToString('o');page_data_included=[bool]$IncludePageData;
 latest_sessions=$recent;sessions=$sessions;recovery_backups=$backups;missing_or_unreadable=$missing;
 note='All session/job JSON reports; latest two framework logs. Page data only with -IncludePageData. Backup ZIPs listed by hash, not embedded. Logs can contain document names. Collection does not establish physical printing or a consistent snapshot of a running bridge.'}
$summary | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $stage 'SUMMARY.json') -Encoding UTF8
@{files=$manifest} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $stage 'MANIFEST.json') -Encoding UTF8
[IO.Compression.ZipFile]::CreateFromDirectory($stage,$zip)
Write-Host 'Results saved. This collector does not change the queue, session locks, or printer.'
Write-Host 'By default, page captures are excluded. Logs and reports may include document names; review before sharing.'
Write-Host $zip
Write-Host ('Collected copies are preserved in: '+$stage)
