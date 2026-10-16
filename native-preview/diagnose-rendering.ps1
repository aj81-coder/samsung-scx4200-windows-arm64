# SPDX-License-Identifier: Apache-2.0
# Runs only the standalone, hash-verified renderer. No bridge/sender, queue or USB operations.
$ErrorActionPreference='Stop'
$renderer=Join-Path $PSScriptRoot 'SCX4200-Render.exe'
$approved=@('183F972BA23AD7E752C52E6E70B29F414B6006B6CA298B89D95080654385A5C2','C02E65A881ED9A1E4C23CE0DC18A339C6D496BDA3D39AEB8C8FBB2009F1E6A03','56BC5FCB582975C710E6941AD55283E9DF647434B3B9278DCAFEA2F41DB3B9F8','1F69DB86DF9327E379FA6AB9D83B42A95A4AA14B5FBCE8E371BB0FE7E49119F6')
$algorithm=[Security.Cryptography.SHA256]::Create()
$inputStream=[IO.File]::OpenRead($renderer)
try{$hash=[BitConverter]::ToString($algorithm.ComputeHash($inputStream)).Replace('-','')}finally{$inputStream.Dispose();$algorithm.Dispose()}
if($hash -notin $approved){throw 'Renderer differs from the tested baseline. No conversion was run.'}
$stamp=Get-Date -Format 'yyyyMMdd-HHmmss-fff'
$report=[ordered]@{schema_version=1;scope='Saved-page conversion only; no printing or queue changes';renderer_sha256=$hash;pages=@();errors=@()}
$runs=@(Get-ChildItem -LiteralPath $PSScriptRoot -Directory | Where-Object Name -match '^bridge-\d' | Sort-Object Name | Select-Object -Last 2)
foreach($run in $runs){
 if($run.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Linked run directories are not supported.'}
 foreach($job in Get-ChildItem -LiteralPath $run.FullName -Directory -Filter 'job-*'){
  if($job.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Linked job directories are not supported.'}
  $failure=Join-Path $job.FullName 'bridge-result.json'
  if(-not (Test-Path -LiteralPath $failure)){continue}
  $result=Get-Content -LiteralPath $failure -Raw | ConvertFrom-Json
  if($result.result -ne 'RENDER_FAILED_NO_USB'){continue}
  $pages=@(Get-ChildItem -LiteralPath $job.FullName -File -Filter 'page-*.pgm')
  if(-not $pages.Count){$report.errors+=($run.Name+'/'+$job.Name+': saved PGM missing');continue}
  foreach($page in $pages){
   if($page.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Linked page files are not supported.'}
   $output=Join-Path $job.FullName ($page.BaseName+'-diagnostic-'+$stamp+'.qpdl')
   if(Test-Path -LiteralPath $output){throw 'Diagnostic output already exists.'}
   $start=New-Object Diagnostics.ProcessStartInfo
   $start.FileName=$renderer
   $start.Arguments='"'+$page.FullName+'" "'+$output+'"'
   $start.WorkingDirectory=$PSScriptRoot
   $start.UseShellExecute=$false;$start.CreateNoWindow=$true
   $start.RedirectStandardError=$true;$start.RedirectStandardOutput=$true
   $process=New-Object Diagnostics.Process;$process.StartInfo=$start
   try{
    if(-not $process.Start()){throw 'Renderer did not start'}
    $stderr=$process.StandardError.ReadToEndAsync();$stdout=$process.StandardOutput.ReadToEndAsync()
    $timedOut=-not $process.WaitForExit(60000)
    if($timedOut){$process.Kill();$process.WaitForExit()}
    $message=$stderr.GetAwaiter().GetResult()
    $null=$stdout.GetAwaiter().GetResult()
    $report.pages+=@{run=$run.Name;job=$job.Name;page=$page.Name;exit_code=$process.ExitCode;timed_out=$timedOut;renderer_message=$message;output_created=(Test-Path -LiteralPath $output)}
    Write-Host ($run.Name+'/'+$page.Name+': '+$message.Trim())
   }finally{$process.Dispose()}
  }
 }
}
if(-not $report.pages.Count){$report.errors+='No saved failed-conversion pages were examined. Keep this script in the existing 0.9.0 folder.'}
$path=Join-Path $PSScriptRoot ('control-render-diagnostic-'+$stamp+'.json')
$success=$report.pages.Count -gt 0 -and $report.errors.Count -eq 0 -and @($report.pages | Where-Object {$_.exit_code -ne 0 -or $_.timed_out}).Count -eq 0
$report['success']=$success
$report | ConvertTo-Json -Depth 7 | Set-Content -LiteralPath $path -Encoding UTF8
Write-Host 'No printing was attempted. Original pages and session locks were left unchanged.'
Write-Host 'Send this JSON report only; it contains converter messages, not page pixels:'
Write-Host $path
if($success){Write-Host 'All examined saved pages converted successfully.'}else{Write-Host 'One or more saved pages could not be converted. Send the JSON; do not retry printing.';exit 1}
