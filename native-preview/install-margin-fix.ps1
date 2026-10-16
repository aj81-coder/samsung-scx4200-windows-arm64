# SPDX-License-Identifier: Apache-2.0
$ErrorActionPreference='Stop'
function Get-Sha256([string]$Path){
 $h=[Security.Cryptography.SHA256]::Create();$s=[IO.File]::OpenRead($Path)
 try{return [BitConverter]::ToString($h.ComputeHash($s)).Replace('-','')}finally{$s.Dispose();$h.Dispose()}
}
$oldHash='183F972BA23AD7E752C52E6E70B29F414B6006B6CA298B89D95080654385A5C2'
$newHash='56BC5FCB582975C710E6941AD55283E9DF647434B3B9278DCAFEA2F41DB3B9F8'
$current=Join-Path $PSScriptRoot 'SCX4200-Render.exe'
$payload=Join-Path $PSScriptRoot 'SCX4200-Render-0.9.2-arm64.exe'
$backup=Join-Path $PSScriptRoot 'SCX4200-Render-before-0.9.2.exe'
if(@(Get-Process -Name 'SCX4200-Reliable-Bridge','SCX4200-Render' -ErrorAction SilentlyContinue).Count){throw 'Stop the bridge/renderer before installing this update.'}
if((Get-Sha256 $payload) -ne $newHash){throw 'Update payload checksum differs. No replacement performed.'}
$before=Get-Sha256 $current
if($before -notin $oldHash,$newHash){throw 'Existing renderer differs from the approved baseline. No replacement performed.'}
if($before -eq $oldHash){
 if(Test-Path -LiteralPath $backup){if((Get-Sha256 $backup) -ne $oldHash){throw 'Backup differs; preserve it and report this.'}}
 else{[IO.File]::Copy($current,$backup,$false)}
 $temp=Join-Path $PSScriptRoot ('renderer-update-'+[guid]::NewGuid().ToString('N')+'.tmp')
 [IO.File]::Copy($payload,$temp,$false)
 if((Get-Sha256 $temp) -ne $newHash){throw 'Staged checksum differs. Existing renderer was not replaced.'}
 if(@(Get-Process -Name 'SCX4200-Reliable-Bridge','SCX4200-Render' -ErrorAction SilentlyContinue).Count){throw 'Bridge became active. Update refused; staged file preserved.'}
 [IO.File]::Replace($temp,$current,[NullString]::Value)
}
if((Get-Sha256 $current) -ne $newHash){throw 'Installed renderer did not verify. Original backup is preserved.'}
# Keep the original package manifest as a baseline record. Update only its
# renderer line when present; never add private captures to a package manifest.
$manifest=Join-Path $PSScriptRoot 'SHA256SUMS.txt'
if(Test-Path -LiteralPath $manifest){
 $saved=Join-Path $PSScriptRoot 'SHA256SUMS-before-0.9.2.txt'
 if(-not (Test-Path -LiteralPath $saved)){[IO.File]::Copy($manifest,$saved,$false)}
 $lines=Get-Content -LiteralPath $manifest
 $lines | ForEach-Object {if($_ -match '^[0-9A-Fa-f]{64}  SCX4200-Render\.exe$'){$newHash+'  SCX4200-Render.exe'}else{$_}} | Set-Content -LiteralPath $manifest -Encoding ASCII
}
@{version='0.9.2';action='Renderer-only margin compatibility update';before_sha256=$before;after_sha256=$newHash;original_backup=[IO.Path]::GetFileName($backup);printing_attempted=$false;session_lock_changed=$false} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $PSScriptRoot ('control-render-update-'+(Get-Date -Format 'yyyyMMdd-HHmmss-fff')+'.json')) -Encoding UTF8
Write-Host 'Renderer update installed. The bridge, USB sender and session lock were not changed.'
Write-Host 'Previously refused margin pages now fit at about 96% size. Pages that already fit retain their output.'
Write-Host 'Run command 6 to check the saved failed pages before printing again.'
