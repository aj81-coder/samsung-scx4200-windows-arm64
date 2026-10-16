# SPDX-License-Identifier: Apache-2.0
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'setup.ps1')
function Invoke-BackgroundUninstall([string]$LocalRoot=$env:LOCALAPPDATA){
 $base=Assert-BackgroundSafePath (Join-Path $LocalRoot 'SCX4200');$app=Assert-BackgroundSafePath (Join-Path $base 'app');$data=Assert-BackgroundSafePath (Join-Path $base 'data')
 Assert-BackgroundStopped $data
 $prepared=Join-Path $base 'installation.json';$complete=Join-Path $base 'installation-complete.json'
 if(!(Test-Path -LiteralPath $prepared)){throw 'No owned installation record exists. Nothing was removed.'}
 $record=Get-Content -LiteralPath $prepared -Raw|ConvertFrom-Json
 if(Test-Path -LiteralPath $complete){$commit=Get-Content -LiteralPath $complete -Raw|ConvertFrom-Json;if($commit.transaction_id -cne $record.transaction_id){throw 'Installation records disagree.'};$record=$commit}
 if($record.schema_version -ne 1 -or $record.transaction_id -notmatch '^[a-f0-9]{32}$' -or $record.state -notin @('Prepared','Installed') -or $record.app -cne $app -or $record.data -cne $data){throw 'Invalid ownership record; nothing was removed.'}
 $expectedStartup=Assert-BackgroundSafePath (Get-BackgroundShortcutPath 'Startup');$expectedMenu=Assert-BackgroundSafePath (Get-BackgroundShortcutPath 'Programs')
 if(@($record.shortcuts).Count -ne 2){throw 'Unexpected shortcut ownership record.'}
 $shortcutSeen=@{}
 foreach($entry in $record.shortcuts){
  if($entry.path -cne $expectedStartup -and $entry.path -cne $expectedMenu){throw 'Unexpected shortcut path.'}
  if($shortcutSeen.ContainsKey([string]$entry.path)){throw 'Duplicate shortcut record.'};$shortcutSeen[[string]$entry.path]=$true
  $null=Assert-BackgroundSafePath $entry.path
  if(Test-Path -LiteralPath $entry.path){
   if($entry.sha256 -notmatch '^[a-f0-9]{64}$' -or (Get-BackgroundHash $entry.path) -cne $entry.sha256){throw 'A shortcut has changed or lacks an ownership receipt. Nothing was removed.'}
   $shortcut=Get-BackgroundShortcut $entry.path
   if($shortcut.TargetPath -ine (Join-Path $app 'SCX4200-Printer.exe') -or $shortcut.Arguments -cne ('--data-dir "'+$data+'"') -or $shortcut.WorkingDirectory -ine $app){throw 'Shortcut target changed. Nothing was removed.'}
  }
 }
 $stage=[string]$record.stage
 if($stage -notmatch ('^'+[regex]::Escape($base)+'\\stage-[a-f0-9]{32}$')){throw 'Invalid recorded stage path.'}
 $null=Assert-BackgroundSafePath $stage
 if((Test-Path -LiteralPath $stage) -and (Test-Path -LiteralPath $app)){throw 'Both staged and installed folders exist. Preserve them for diagnosis.'}
 $payload=$app;if(Test-Path -LiteralPath $stage){$payload=$stage}
 $owned=@();$seen=@{};$hashes=@{}
 foreach($file in $record.files){
  $relative=[string]$file.path
  if(!$relative -or $relative -match '(^[\\/]|:|(^|[\\/])\.\.?([\\/]|$))' -or $file.sha256 -notmatch '^[a-f0-9]{64}$' -or $seen.ContainsKey($relative)){throw 'Invalid file ownership record.'};$seen[$relative]=$true;$hashes[$relative]=[string]$file.sha256
  $path=Assert-BackgroundSafePath (Join-Path $payload $relative)
  if(!$path.StartsWith($payload+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Owned file escaped the application folder.'}
  if(Test-Path -LiteralPath $path){if(!(Test-Path -LiteralPath $path -PathType Leaf) -or (Get-BackgroundHash $path) -cne $file.sha256){throw ('An installed file changed. Preserve it for diagnosis: '+$relative)};$owned+=$path}
 }
 # Recheck immediately before changes. Data and every printer queue are preserved.
 Assert-BackgroundStopped $data
 foreach($entry in $record.shortcuts){if(Test-Path -LiteralPath $entry.path){if((Get-BackgroundHash $entry.path) -cne $entry.sha256){throw 'Shortcut changed during removal.'};Remove-Item -LiteralPath $entry.path}}
 foreach($path in $owned){$relative=$path.Substring($payload.Length+1);if((Get-BackgroundHash $path) -cne $hashes[$relative]){throw 'File changed during removal.'};Remove-Item -LiteralPath $path}
 # Remove empty directories only, deepest first. Unknown files keep their folder.
 if(Test-Path -LiteralPath $payload){
  foreach($directory in @(Get-ChildItem -LiteralPath $payload -Directory -Recurse -Force|Sort-Object {$_.FullName.Length} -Descending)){$null=Assert-BackgroundSafePath $directory.FullName;if(!@(Get-ChildItem -LiteralPath $directory.FullName -Force).Count){[IO.Directory]::Delete($directory.FullName)}}
  if(!@(Get-ChildItem -LiteralPath $payload -Force).Count){[IO.Directory]::Delete($payload)}
 }
 $suffix='.uninstalled-'+[DateTime]::UtcNow.ToString('yyyyMMddHHmmssfff')
 foreach($path in @($prepared,$complete)){if(Test-Path -LiteralPath $path){[IO.File]::Move($path,$path+$suffix)}}
 Write-Host 'Removed the owned application and startup shortcuts. Printer queues and diagnostic data were preserved.'
}
if($MyInvocation.InvocationName -ne '.') {try{Invoke-BackgroundUninstall}catch{Write-Error $_;exit 1}}


