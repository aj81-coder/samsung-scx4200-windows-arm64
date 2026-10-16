# SPDX-License-Identifier: Apache-2.0
param([ValidateSet('x64','arm64')][string]$Architecture='x64',[switch]$PrepareOnly)
$ErrorActionPreference='Stop'
if($PSVersionTable.PSVersion.Major -lt 7){throw 'Run this build with PowerShell 7.'}
$root=Split-Path $PSScriptRoot -Parent
$zig=Join-Path $root '.tools/zig-x86_64-windows-0.15.2/zig.exe'
$pappl=Join-Path $root 'build/pappl-1.4.10'
$cups=Join-Path $root 'build/cups-2.4.11'
$existing=Join-Path $root ('build/async/dep/'+$Architecture)
$out=Join-Path $root ('build/general/dep/'+$Architecture)
$config=Join-Path $out 'pappl-config'
$pins=[ordered]@{
 'config.h'='1BF9590550FB326FE52F8A1D3E7106C44EC7651F79011A58814D9238778C6211'
 'job-ipp.c'='376D78AA90A7BAE73A96519EE113CB76611CE998163A7562D5705C42CA44137E'
 'job-process.c'='6638933EF009D4CB36B93EFF0E873B29EBCF8BAD0DBF8CE79372A71FC28BD1C8'
 'job.c'='EC0BA6C500A6CD2BED154D3C2282BDE33C1C7F432155BB861A82496C81111C5D'
 'system-accessors.c'='B27A2FF37A9357BEB88E9EF84544B9AECB4A0F4ED0D9377D900C641B76F15990'
 'win32-pthread.c'='ADCCB8F272510AD7521258D1E833BF6008631CF1039D7398A914D613488FC6ED'
}
foreach($file in @($zig,(Join-Path $pappl 'vcnet/libpappl1.vcxproj'),(Join-Path $cups 'cups/cups.h'),(Join-Path $existing 'cups-import.lib'),(Join-Path $existing 'cups.dll'),(Join-Path $existing 'pappl.lib'))){
 if(!(Test-Path -LiteralPath $file -PathType Leaf)){throw "Missing prerequisite: $file. Build the existing guarded asynchronous dependencies first."}
}
$archive=Join-Path $root 'build/pappl-1.4.10.zip'
if(!(Test-Path -LiteralPath $archive) -or (Get-FileHash -LiteralPath $archive).Hash -ne '1E93FFC841EA560B93A3F699BC0F3B3220AC4DF2E0F0934F0C30F62BB8C6C72F'){throw 'Pinned PAPPL 1.4.10 archive missing or changed.'}
foreach($name in $pins.Keys){
 $file=Join-Path (Join-Path $existing 'pappl-config') $name
 if(!(Test-Path -LiteralPath $file) -or (Get-FileHash -LiteralPath $file).Hash -ne $pins[$name]){throw "Guarded prerequisite changed: $name. Review its policy before rebuilding."}
}
$baseline=@{};foreach($name in @('pappl.lib','cups-import.lib','cups.dll')){$baseline[$name]=(Get-FileHash -LiteralPath (Join-Path $existing $name)).Hash}
New-Item -ItemType Directory -Force $config | Out-Null
foreach($name in $pins.Keys){Copy-Item -LiteralPath (Join-Path (Join-Path $existing 'pappl-config') $name) -Destination (Join-Path $config $name) -Force}
$file=Join-Path $config 'job-process.c'
$text=[IO.File]::ReadAllText($file).Replace("`r`n","`n")
$anchor="  _papplJobSetRetain(job);`n`n  printer->processing_job = NULL;"
$at=$text.IndexOf($anchor,[StringComparison]::Ordinal)
if($at -lt 0 -or $text.IndexOf($anchor,$at+$anchor.Length,[StringComparison]::Ordinal) -ge 0){throw 'PAPPL retention policy anchor must occur exactly once.'}
$replacement=@'
  _papplJobSetRetain(job);
  /* SCX background policy: terminal document data is never retained, including
   * when a client supplies job-retain-* attributes. No job is reprinted. */
  job->retain_until = 0;

  printer->processing_job = NULL;
'@
$text=$text.Substring(0,$at)+$replacement+$text.Substring($at+$anchor.Length)
[IO.File]::WriteAllText($file,$text,[Text.UTF8Encoding]::new($false))
$jobFile=Join-Path $config 'job.c'
$jobText=[IO.File]::ReadAllText($jobFile).Replace("`r`n","`n")
$deleteAnchor=@'
    if ((!strncmp(job->filename, job->system->directory, dirlen) && job->filename[dirlen] == '/') || (!strncmp(job->filename, tempdir, templen) && job->filename[templen] == '/'))
      unlink(job->filename);
'@
$deleteAt=$jobText.IndexOf($deleteAnchor,[StringComparison]::Ordinal)
if($deleteAt -lt 0 -or $jobText.IndexOf($deleteAnchor,$deleteAt+$deleteAnchor.Length,[StringComparison]::Ordinal) -ge 0){throw 'PAPPL owned spool removal anchor must occur exactly once.'}
$deleteReplacement=@'
    if ((!strncmp(job->filename, job->system->directory, dirlen) && job->filename[dirlen] == '/') || (!strncmp(job->filename, tempdir, templen) && job->filename[templen] == '/'))
    {
      /* Windows maps the framework's creation mode 0400 to FILE_ATTRIBUTE_READONLY.
       * Change only a file already admitted by PAPPL's owned-path boundary. */
      _chmod(job->filename, 0600);
      unlink(job->filename);
    }
'@
$jobText=$jobText.Substring(0,$deleteAt)+$deleteReplacement+$jobText.Substring($deleteAt+$deleteAnchor.Length)
$createAnchor='    return (open(fname, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW | O_CLOEXEC | O_BINARY, 0400));'
$createAt=$jobText.IndexOf($createAnchor,[StringComparison]::Ordinal)
if($createAt -lt 0 -or $jobText.IndexOf($createAnchor,$createAt+$createAnchor.Length,[StringComparison]::Ordinal) -ge 0){throw 'PAPPL spool creation mode anchor must occur exactly once.'}
$createReplacement="    /* Writable CRT mode avoids Windows ReadOnly files on rejected-upload paths.`n     * The per-user data folder's Windows ACL remains the access boundary. */`n"+$createAnchor.Replace(', 0400)',', 0600)')
$jobText=$jobText.Substring(0,$createAt)+$createReplacement+$jobText.Substring($createAt+$createAnchor.Length)
[IO.File]::WriteAllText($jobFile,$jobText,[Text.UTF8Encoding]::new($false))
# Stream uploads into the owned spool file without a fixed document size.
$ippFile=Join-Path $config 'job-ipp.c'
$ippText=[IO.File]::ReadAllText($ippFile).Replace("`r`n","`n")
function Replace-GeneralAnchor([string]$Text,[string]$Anchor,[string]$Replacement){
 $at=$Text.IndexOf($Anchor,[StringComparison]::Ordinal)
 if($at -lt 0 -or $Text.IndexOf($Anchor,$at+$Anchor.Length,[StringComparison]::Ordinal) -ge 0){throw 'General upload policy anchor must occur exactly once.'}
 return $Text.Substring(0,$at)+$Replacement+$Text.Substring($at+$Anchor.Length)
}
$uploadHelper=@'
#include <windows.h>
#include <stdint.h>
/* SCX_GENERAL_UPLOAD_POLICY_BEGIN
 * Signed counters must not overflow. Check actual free space at least every
 * MiB, leaving a 128 MiB reserve plus that interval before admitting a chunk.
 * This bounds resources, not document length. Disk/write failures remain fatal.
 */
static bool
scx_upload_chunk_allowed(ssize_t total, ssize_t bytes, bool canceled,
                         const char *directory, uint64_t *next_disk_check)
{
  const uint64_t interval = 1024ULL * 1024ULL;
  const uint64_t reserve = 128ULL * 1024ULL * 1024ULL;
  if (canceled || total < 0 || bytes <= 0 || bytes > 4096 ||
      (uint64_t)total > ((uint64_t)SIZE_MAX >> 1) - (uint64_t)bytes)
    return false;
  if ((uint64_t)total >= *next_disk_check)
  {
    ULARGE_INTEGER available;
    if (!GetDiskFreeSpaceExA(directory, &available, NULL, NULL) ||
        available.QuadPart < reserve + interval)
      return false;
    *next_disk_check = (uint64_t)total + interval;
  }
  return true;
}
/* SCX_GENERAL_UPLOAD_POLICY_END */
'@
$ippText=Replace-GeneralAnchor $ippText '#include "pappl-private.h"' ('#include "pappl-private.h"'+"`n"+$uploadHelper)
$ippText=Replace-GeneralAnchor $ippText "  cups_array_t`t`t*ra;`t`t// Attributes to send in response" ("  uint64_t next_disk_check = 0;`n"+"  cups_array_t`t`t*ra;`t`t// Attributes to send in response")
$ippText=Replace-GeneralAnchor $ippText 'if (papplJobIsCanceled(job) || total > (32 * 1024 * 1024) - bytes)' 'if (!scx_upload_chunk_allowed(total, bytes, papplJobIsCanceled(job), client->system->directory, &next_disk_check))'
$ippText=Replace-GeneralAnchor $ippText 'Canceled or document exceeds 32 MiB decompressed limit.' 'Canceled, spool space unavailable, or document counter overflow.'
$ippText=Replace-GeneralAnchor $ippText '"Received %lu bytes of document data.", (unsigned long)total' '"Received %llu bytes of document data.", (unsigned long long)total'
[IO.File]::WriteAllText($ippFile,$ippText,[Text.UTF8Encoding]::new($false))
$report=[ordered]@{policy='general-disk-stream-upload-and-terminal-removal-v4';architecture=$Architecture;patch_count=4;upload_fixed_size_cap=$false;upload_free_space_reserve_bytes=134217728;upload_disk_check_interval_bytes=1048576;patched_job_ipp_sha256=(Get-FileHash -LiteralPath $ippFile).Hash;input_job_process_sha256=$pins['job-process.c'];patched_job_process_sha256=(Get-FileHash -LiteralPath $file).Hash;patched_job_sha256=(Get-FileHash -LiteralPath $jobFile).Hash;retention_attributes_overridden=$true;owned_readonly_spool_cleanup=$true;writable_spool_creation=$true;usb_access=$false;source_config_pins=$pins;unchanged_dependencies=$baseline;compiled=$false}
if(!$PrepareOnly){
 $env:ZIG_GLOBAL_CACHE_DIR=Join-Path $root '.cache/zig-global'
 $env:ZIG_LOCAL_CACHE_DIR=Join-Path $root '.cache/zig-local'
 $version=& $zig version;if($LASTEXITCODE -ne 0 -or $version -ne '0.15.2'){throw 'Pinned Zig 0.15.2 required.'}
 [xml]$project=Get-Content -LiteralPath (Join-Path $pappl 'vcnet/libpappl1.vcxproj')
 $replacements=@('win32-pthread.c','system-accessors.c','job-ipp.c','job-process.c','job.c')
 $sources=@($project.Project.ItemGroup.ClCompile.Include | Where-Object { $_ -and $_ -ne 'dns_sd.c' } | ForEach-Object { Join-Path (Join-Path $pappl 'vcnet') $_ } | Where-Object { (Split-Path $_ -Leaf) -notin $replacements })
 $sources+=@($replacements | ForEach-Object {Join-Path $config $_})
 $target=if($Architecture -eq 'arm64'){'aarch64-windows-gnu'}else{'x86_64-windows-gnu'}
 $arguments=@('build-lib','-target',$target,'-O','ReleaseFast','-lc','-DWIN32','-I',$config,'-I',$cups,'-I',$pappl,'-I',(Join-Path $pappl 'pappl'),'-cflags','-std=gnu11','--')+$sources+@('-femit-bin='+(Join-Path $out 'pappl.lib'))
 & $zig @arguments
 if($LASTEXITCODE -ne 0){throw 'General PAPPL build failed.'}
 $report.compiled=$true;$report.library_sha256=(Get-FileHash -LiteralPath (Join-Path $out 'pappl.lib')).Hash
}
foreach($name in $baseline.Keys){if((Get-FileHash -LiteralPath (Join-Path $existing $name)).Hash -ne $baseline[$name]){throw "Existing tested dependency unexpectedly changed: $name"}}
$report | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $out 'framework-policy.json') -Encoding utf8NoBOM
Write-Output (Join-Path $out 'framework-policy.json')
