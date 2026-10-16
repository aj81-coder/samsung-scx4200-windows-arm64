# SPDX-License-Identifier: Apache-2.0
param([string]$PreparedFolder)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if (!$PreparedFolder) { $PreparedFolder = Read-Host 'Paste the prepared folder shown by the prepare step' }
$PreparedFolder = $PreparedFolder.Trim('"')
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'prepared'))
$folder = [IO.Path]::GetFullPath($PreparedFolder)
if ([IO.Path]::GetDirectoryName($folder) -ne $root -or [IO.Path]::GetFileName($folder) -notmatch '^[a-f0-9]{64}$') { throw 'Choose a job folder directly inside this package prepared folder.' }
foreach ($path in @($root,$folder)) { if ((Get-Item -LiteralPath $path).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Linked folders are not supported.' } }
$manifestPath = Join-Path $folder 'manifest.json'
$m = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
if ($m.schema -ne 1 -or $m.source_identity -ne [IO.Path]::GetFileName($folder) -or $m.physical_printing -ne $false) { throw 'Invalid prepared-job manifest.' }
foreach ($pair in @(@('page.pgm',$m.pgm_sha256),@('page.qpdl',$m.qpdl_sha256),@('preview.bmp',$m.preview_sha256))) {
 $path = Join-Path $folder $pair[0]
 if ((Get-Item -LiteralPath $path).Attributes -band [IO.FileAttributes]::ReparsePoint -or $pair[1] -notmatch '^[a-fA-F0-9]{64}$' -or (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ne $pair[1]) { throw "Prepared file changed: $($pair[0]). Nothing sent." }
}
$sender = Join-Path $PSScriptRoot 'scx4200-render-print-arm64.exe'
$qpdl = Join-Path $folder 'page.qpdl'
& $sender --job $qpdl --sha256 $m.qpdl_sha256 --validate-only
if ($LASTEXITCODE -ne 0) { throw 'Validation failed. Nothing sent.' }
# CreateNew atomically refuses a second attempt, even if a prior run crashed or
# the sender was cancelled. Mark BEFORE invoking anything that can write USB.
$marker = Join-Path $folder 'PRINT-ATTEMPTED.txt'
if (Test-Path -LiteralPath $marker) { throw 'This page has already had a print attempt. Do not retry; send the results for review.' }
$stream = [IO.File]::Open($marker,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
try { $bytes=[Text.Encoding]::UTF8.GetBytes([DateTime]::UtcNow.ToString('o') + "`r`nDo not retry this job. Send the results for review.`r`n"); $stream.Write($bytes,0,$bytes.Length); $stream.Flush($true) } finally { $stream.Dispose() }
Write-Host 'Confirm that you checked preview.bmp. The native sender will require typing PRINT.'
& $sender --job $qpdl --sha256 $m.qpdl_sha256
$result = $LASTEXITCODE
@{ sender_exit_code=$result; finished_utc=[DateTime]::UtcNow.ToString('o') } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $folder 'attempt-result.json') -Encoding UTF8
if ($result -ne 0) { throw 'The send attempt did not finish successfully. Do not retry; send the results.' }
Write-Host 'Check the physical page and report whether it matches preview.bmp. Do not print this job again.'
