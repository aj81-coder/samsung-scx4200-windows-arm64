# SPDX-License-Identifier: Apache-2.0
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$out=Join-Path $root ('build/margin-fix/installer-tests-'+(Get-Date -Format 'yyyyMMdd-HHmmss-fff'))
New-Item -ItemType Directory -Path $out | Out-Null
$old=Join-Path $root 'dist/SCX4200-Foreground-Preview-0.9.0-arm64/SCX4200-Render.exe'
$new=Join-Path $root 'build/margin-fix/arm64/SCX4200-Render.exe'
$results=@()
foreach($case in @('install','active','unknown','bad-payload','backup-conflict')){
 $dir=Join-Path $out $case;New-Item -ItemType Directory -Path $dir | Out-Null
 Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'install-margin-fix.ps1') -Destination $dir
 Copy-Item -LiteralPath $old -Destination (Join-Path $dir 'SCX4200-Render.exe')
 Copy-Item -LiteralPath $new -Destination (Join-Path $dir 'SCX4200-Render-0.9.2-arm64.exe')
 Set-Content -LiteralPath (Join-Path $dir 'SESSION-ACTIVE.lock') 'Preserve original session lock'
 $oldHash=(Get-FileHash -LiteralPath $old).Hash
 Set-Content -LiteralPath (Join-Path $dir 'SHA256SUMS.txt') ($oldHash+'  SCX4200-Render.exe')
 if($case -eq 'unknown'){Set-Content -LiteralPath (Join-Path $dir 'SCX4200-Render.exe') 'Unknown renderer'}
 if($case -eq 'bad-payload'){Set-Content -LiteralPath (Join-Path $dir 'SCX4200-Render-0.9.2-arm64.exe') 'Corrupt update'}
 if($case -eq 'backup-conflict'){Set-Content -LiteralPath (Join-Path $dir 'SCX4200-Render-before-0.9.2.exe') 'Keep existing backup'}
 $before=(Get-FileHash -LiteralPath (Join-Path $dir 'SCX4200-Render.exe')).Hash
 $active=if($case -eq 'active'){1}else{0}
 $wrapper="function Get-Process {if($active){[pscustomobject]@{Id=123}}}; & (Join-Path `$PSScriptRoot 'install-margin-fix.ps1')"
 [IO.File]::WriteAllText((Join-Path $dir 'mocks.ps1'),$wrapper,[Text.Encoding]::UTF8)
 try{$ErrorActionPreference='Continue';$messages=& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $dir 'mocks.ps1') 2>&1;$code=$LASTEXITCODE}finally{$ErrorActionPreference='Stop'}
 $messages | Out-String | Set-Content -LiteralPath (Join-Path $dir 'output.txt')
 if($case -eq 'install'){
  if($code -ne 0 -or (Get-FileHash -LiteralPath (Join-Path $dir 'SCX4200-Render.exe')).Hash -ne (Get-FileHash -LiteralPath $new).Hash){throw 'Install failed'}
  if((Get-FileHash -LiteralPath (Join-Path $dir 'SCX4200-Render-before-0.9.2.exe')).Hash -ne $oldHash){throw 'Original not preserved'}
  if((Get-Content -LiteralPath (Join-Path $dir 'SHA256SUMS.txt') -Raw).Trim() -ne ((Get-FileHash -LiteralPath $new).Hash+'  SCX4200-Render.exe')){throw 'Manifest not updated'}
  & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $dir 'mocks.ps1')
  if($LASTEXITCODE -ne 0){throw 'Already-installed rerun failed'}
 }else{
  if($code -eq 0){throw ('Unsafe installer acceptance: '+$case)}
  if((Get-FileHash -LiteralPath (Join-Path $dir 'SCX4200-Render.exe')).Hash -ne $before){throw 'Refusal changed existing renderer'}
 }
 if((Get-Content -LiteralPath (Join-Path $dir 'SESSION-ACTIVE.lock') -Raw).Trim() -ne 'Preserve original session lock'){throw 'Installer touched session lock'}
 if($case -eq 'backup-conflict' -and (Get-Content -LiteralPath (Join-Path $dir 'SCX4200-Render-before-0.9.2.exe') -Raw).Trim() -ne 'Keep existing backup'){throw 'Existing backup changed'}
 $results+=@{name=$case;result='PASS'}
}
@{result='PASS';tests=$results;installer_sha256=(Get-FileHash -LiteralPath (Join-Path $PSScriptRoot 'install-margin-fix.ps1')).Hash;scope='Isolated files and mocked process reads; no printing, queue, or USB access'} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $out 'results.json')
Write-Host $out
