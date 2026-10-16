# SPDX-License-Identifier: Apache-2.0
param([string]$CaptureFolder)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if (!$CaptureFolder) { $CaptureFolder = Read-Host 'Paste the old capture package folder (or one capture run folder)' }
$CaptureFolder = $CaptureFolder.Trim('"')
if (![IO.Path]::IsPathRooted($CaptureFolder)) { throw 'Use an absolute capture folder path.' }
$source = (Get-Item -LiteralPath $CaptureFolder).FullName
if (!(Test-Path -LiteralPath $source -PathType Container)) { throw 'Capture folder not found.' }
# The capture program must be stopped first: this is a completed-file handoff.
if (@(Get-ChildItem -LiteralPath $source -Recurse -File -Filter 'job-*-page-*.partial').Count) { throw 'Incomplete capture files are present. Choose a completed, stopped capture run folder.' }
$pages = @(Get-ChildItem -LiteralPath $source -Recurse -File -Filter 'job-*-page-*.json' | Sort-Object LastWriteTimeUtc -Descending)
if (!$pages.Count) { throw 'No completed captured page was found.' }
$latest = $pages[0]
if ($pages.Count -gt 1 -and $pages[1].LastWriteTimeUtc -eq $latest.LastWriteTimeUtc) { throw 'Newest page is ambiguous. Choose the exact capture run folder.' }
if ($latest.BaseName -notmatch '^(job-\d+)-page-01$') { throw 'Latest job is not a single first page. Print a new one-page sample.' }
$jobPrefix = $Matches[1]
$jobFiles = @(Get-ChildItem -LiteralPath $latest.DirectoryName -File | Where-Object { $_.Name.StartsWith($jobPrefix + '-page-') })
if ($jobFiles.Count -ne 2 -or @($jobFiles | Where-Object { $_.Extension -notin '.json','.rows' }).Count) { throw 'Job has multiple pages, incomplete files, or unexpected files. Use a fresh one-page sample.' }
$meta = Get-Content -LiteralPath $latest.FullName -Raw | ConvertFrom-Json
if ($jobPrefix -ne ('job-{0:D6}' -f [int]$meta.job_id)) { throw 'Capture job identity does not match its filename.' }
if ($meta.outcome -ne 'PAGE_CALLBACK_COMPLETE_ONLY' -or $meta.physical_printing -ne $false -or $meta.page -ne 1 -or $meta.width -ne 2480 -or $meta.height -ne 3507 -or $meta.bytes_per_line -ne 2480 -or $meta.bits_per_pixel -ne 8 -or $meta.color_space -ne 18 -or $meta.resolution.Count -ne 2 -or $meta.resolution[0] -ne 300 -or $meta.resolution[1] -ne 300 -or $meta.captured_bytes -ne 8697360 -or $meta.sha256 -notmatch '^[a-fA-F0-9]{64}$') { throw 'Unsupported capture metadata. Requires one A4 300 dpi grayscale page.' }
$rowsPath = Join-Path $latest.DirectoryName ($latest.BaseName + '.rows')
if ((Get-Item -LiteralPath $rowsPath).Length -ne 8697360) { throw 'Captured rows length does not match.' }
$rows = [IO.File]::ReadAllBytes($rowsPath)
$rowsHasher = [Security.Cryptography.SHA256]::Create()
try { $rowsHash = ([BitConverter]::ToString($rowsHasher.ComputeHash($rows))).Replace('-','') } finally { $rowsHasher.Dispose() }
if ($rows.Length -ne 8697360 -or $rowsHash -ne $meta.sha256) { throw 'Captured rows length or SHA256 does not match.' }
$renderer = Join-Path $PSScriptRoot 'SCX4200-Render.exe'
$sender = Join-Path $PSScriptRoot 'scx4200-render-print-arm64.exe'
if (!(Test-Path -LiteralPath $renderer) -or !(Test-Path -LiteralPath $sender)) { throw 'Extract the complete package before running this script.' }
# A stable capture identity prevents preparing the same job into another folder
# in this package. Never delete prepared folders or attempt markers to retry.
$sha = [Security.Cryptography.SHA256]::Create()
try { $identity = ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($latest.FullName.ToLowerInvariant() + '|' + $meta.sha256.ToLowerInvariant())))).Replace('-','').ToLowerInvariant() } finally { $sha.Dispose() }
$preparedRoot = Join-Path $PSScriptRoot 'prepared'
[IO.Directory]::CreateDirectory($preparedRoot) | Out-Null
if ((Get-Item -LiteralPath $preparedRoot).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Linked prepared folders are not supported.' }
$out = Join-Path $preparedRoot $identity
if (Test-Path -LiteralPath $out) { throw "This capture was already prepared or attempted: $out . Do not retry it; send the results for review." }
[IO.Directory]::CreateDirectory($out) | Out-Null
$pgm = Join-Path $out 'page.pgm'
$stream = [IO.File]::Create($pgm)
try { $header = [Text.Encoding]::ASCII.GetBytes("P5`n2480 3507`n255`n"); $stream.Write($header,0,$header.Length); $stream.Write($rows,0,$rows.Length) } finally { $stream.Dispose() }
$qpdl = Join-Path $out 'page.qpdl'
$renderProcess = Start-Process -FilePath $renderer -ArgumentList @(('"' + $pgm + '"'),('"' + $qpdl + '"')) -RedirectStandardError (Join-Path $out 'render.log') -WindowStyle Hidden -Wait -PassThru
if ($renderProcess.ExitCode -ne 0) { throw "Rendering failed. Keep $out for investigation." }
$jobHash = (Get-FileHash -LiteralPath $qpdl -Algorithm SHA256).Hash
& $sender --job $qpdl --sha256 $jobHash --validate-only
if ($LASTEXITCODE -ne 0) { throw 'Printer-data validation failed. Nothing was sent.' }
# A standard 1-bit BMP: black palette entry 0, white entry 1, padded white
# bottom rows. Same ordered dither as the renderer; no target Python needed.
Add-Type -TypeDefinition @'
using System; using System.IO;
public static class ScxPreview {
 public static void Write(byte[] gray,string path) {
  int w=2480,h=3509,stride=((w+31)/32)*4;
  int[,] m={{0,8,2,10},{12,4,14,6},{3,11,1,9},{15,7,13,5}};
  using(var b=new BinaryWriter(new FileStream(path,FileMode.CreateNew))) {
   b.Write((ushort)0x4d42); b.Write(62+stride*h); b.Write(0); b.Write(62);
   b.Write(40); b.Write(w); b.Write(h); b.Write((ushort)1); b.Write((ushort)1);
   b.Write(0); b.Write(stride*h); b.Write(11811); b.Write(11811); b.Write(2); b.Write(2);
   b.Write(0); b.Write(0x00ffffff);
   for(int y=h-1;y>=0;y--) { var line=new byte[stride]; for(int i=0;i<stride;i++)line[i]=255;
    if(y<3507)for(int x=0;x<w;x++)if(gray[y*w+x]<m[y%4,x%4]*16+8)line[x/8]&=(byte)~(0x80>>(x%8));
    b.Write(line);
   }
  }
 }
}
'@
$preview = Join-Path $out 'preview.bmp'
[ScxPreview]::Write($rows,$preview)
$manifest = [ordered]@{ schema=1; source_identity=$identity; source_metadata=$latest.FullName; source_sha256=$meta.sha256; job_id=$meta.job_id; pgm_sha256=(Get-FileHash -LiteralPath $pgm).Hash; qpdl_sha256=$jobHash; preview_sha256=(Get-FileHash -LiteralPath $preview).Hash; prepared_utc=[DateTime]::UtcNow.ToString('o'); physical_printing=$false }
$manifest | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $out 'manifest.json') -Encoding UTF8
Write-Host "Prepared successfully. No data was sent to USB."
Write-Host "Open and check this preview: $preview"
Write-Host "Prepared folder for the print step: $out"
