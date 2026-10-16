# SPDX-License-Identifier: Apache-2.0
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$zig=Join-Path $root '.tools/zig-x86_64-windows-0.15.2/zig.exe'
$env:ZIG_GLOBAL_CACHE_DIR=Join-Path $root '.cache/zig-global'
$env:ZIG_LOCAL_CACHE_DIR=Join-Path $root '.cache/zig-local'
$out=Join-Path $root ('build/background/framework-policy-tests-'+(Get-Date -Format 'yyyyMMdd-HHmmss-fff'))
New-Item -ItemType Directory $out | Out-Null
$snippets=@();$removeFunctions=@();$results=@()
foreach($arch in @('x64','arm64')){
 $deps=Join-Path $root ('build/background/dep/'+$arch)
 $report=Get-Content -LiteralPath (Join-Path $deps 'framework-policy.json') -Raw | ConvertFrom-Json
 $source=Join-Path $deps 'pappl-config/job-process.c'
 $text=[IO.File]::ReadAllText($source).Replace("`r`n","`n")
 if($report.patch_count -ne 3 -or $report.patched_job_process_sha256 -ne (Get-FileHash -LiteralPath $source).Hash){throw 'Policy source/hash mismatch.'}
 $start=$text.IndexOf('  _papplJobSetRetain(job);',[StringComparison]::Ordinal)
 $end=$text.IndexOf('    _papplJobRemoveFile(job);',$start,[StringComparison]::Ordinal)
 if($start -lt 0 -or $end -lt $start -or $text.IndexOf('  _papplJobSetRetain(job);',$start+1,[StringComparison]::Ordinal) -ge 0){throw 'Ambiguous actual framework policy extraction.'}
 $snippets+= $text.Substring($start,$end+'    _papplJobRemoveFile(job);'.Length-$start)
 $jobPath=Join-Path $deps 'pappl-config/job.c'
 if((Get-FileHash -LiteralPath $jobPath).Hash -ne $report.patched_job_sha256){throw 'Patched file removal source/hash mismatch.'}
 $jobText=[IO.File]::ReadAllText($jobPath).Replace("`r`n","`n")
 if(-not $jobText.Contains('open(fname, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW | O_CLOEXEC | O_BINARY, 0600)')){throw 'Writable spool creation policy missing.'}
 $removeStart=$jobText.IndexOf("void`n_papplJobRemoveFile(",[StringComparison]::Ordinal)
 $removeEnd=$jobText.IndexOf("`n}`n",$removeStart,[StringComparison]::Ordinal)
 if($removeStart -lt 0 -or $removeEnd -lt $removeStart){throw 'Actual file removal function not found.'}
 $removeFunctions+=$jobText.Substring($removeStart,$removeEnd+2-$removeStart)
 foreach($property in $report.source_config_pins.PSObject.Properties){
  if((Get-FileHash -LiteralPath (Join-Path $root ('build/async/dep/'+$arch+'/pappl-config/'+$property.Name))).Hash -ne $property.Value){throw 'Original guarded input changed.'}
 }
 foreach($property in $report.unchanged_dependencies.PSObject.Properties){
  if((Get-FileHash -LiteralPath (Join-Path $root ('build/async/dep/'+$arch+'/'+$property.Name))).Hash -ne $property.Value){throw 'Original tested dependency changed.'}
 }
 $results+=@{architecture=$arch;patch_count=3;original_dependencies_unchanged=$true;patched_source_verified=$true;writable_spool_creation=$true}
}
if($snippets[0] -cne $snippets[1] -or $removeFunctions[0] -cne $removeFunctions[1]){throw 'Architectures use different cleanup policies.'}
$head=@'
#include <stddef.h>
enum { IPP_JSTATE_PROCESSING=5, IPP_JSTATE_CANCELED=7, IPP_JSTATE_ABORTED=8, IPP_JSTATE_COMPLETED=9 };
typedef struct {int state,removed; long retain_until,requested_retention;} job_t;
typedef struct {int max_preserved_jobs; job_t *processing_job;} printer_t;
static void _papplJobSetRetain(job_t *job){job->retain_until=job->requested_retention;}
static void _papplJobRemoveFile(job_t *job){job->removed++;}
static void actual_cleanup_policy(job_t *job,printer_t *printer){
'@
$tail=@'
}
int main(void){
 int cases=0;
 for(int state=5;state<=9;state++)for(int request=0;request<3;request++){
  job_t job={state,0,0,request==0?0:request==1?444:2147483647};
  printer_t printer={0,&job}; actual_cleanup_policy(&job,&printer);
  if(job.removed!=(state>=IPP_JSTATE_CANCELED)||job.retain_until!=0||printer.processing_job!=NULL)return 10+cases;
  cases++;
 }
 return cases==15?0:99;
}
'@
$file=Join-Path $out 'actual-framework-policy.c'
[IO.File]::WriteAllText($file,$head+"`n"+$snippets[0]+"`n"+$tail,[Text.UTF8Encoding]::new($false))
$exe=Join-Path $out 'actual-framework-policy.exe'
& $zig cc -target x86_64-windows-gnu -std=c11 -Wall -Wextra -Werror $file -o $exe
if($LASTEXITCODE -ne 0){throw 'Actual framework policy test failed to compile.'}
& $exe
if($LASTEXITCODE -ne 0){throw "Actual framework cleanup failed case $LASTEXITCODE"}
$removeHead=@'
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <io.h>
#include <direct.h>
#include <sys/stat.h>
#include <windows.h>
typedef struct {char *directory;} system_t;
typedef struct {char *filename;system_t *system;} pappl_job_t;
static const char *papplGetTempDir(void){return "unused-test-temp-root";}
'@
$removeTail=@'
int main(int argc,char **argv){
 if(argc!=2)return 1;
 char spool[4096],other[4096],file[4096];
 snprintf(spool,sizeof(spool),"%s/spool",argv[1]);
 snprintf(other,sizeof(other),"%s/spool-other",argv[1]);
 if(_mkdir(spool)||_mkdir(other))return 2;
 system_t system={spool};
 for(int owned=0;owned<2;owned++){
  int n=snprintf(file,sizeof(file),"%s/fixture.pwg",owned?spool:other);
  if(n<0||n>=(int)sizeof(file))return 3;
  FILE *output=fopen(file,"wb");if(!output)return 4;
  if(fputs("private device-free fixture",output)<0||fclose(output))return 5;
  if(_chmod(file,0400))return 6;
  DWORD before=GetFileAttributesA(file);if(before==INVALID_FILE_ATTRIBUTES||!(before&FILE_ATTRIBUTE_READONLY))return 7;
  pappl_job_t job={strdup(file),&system};if(!job.filename)return 8;
  _papplJobRemoveFile(&job);
  if(job.filename)return 9;
  DWORD after=GetFileAttributesA(file);
  if(owned){if(after!=INVALID_FILE_ATTRIBUTES||GetLastError()!=ERROR_FILE_NOT_FOUND)return 10;}
  else {if(after==INVALID_FILE_ATTRIBUTES||!(after&FILE_ATTRIBUTE_READONLY))return 11;if(_chmod(file,0600)||unlink(file))return 12;}
 }
 return 0;
}
'@
$removeFile=Join-Path $out 'actual-framework-file-removal.c'
[IO.File]::WriteAllText($removeFile,$removeHead+"`n"+$removeFunctions[0]+"`n"+$removeTail,[Text.UTF8Encoding]::new($false))
$removeExe=Join-Path $out 'actual-framework-file-removal.exe'
& $zig cc -target x86_64-windows-gnu -std=c11 -Wall -Wextra -Werror $removeFile -o $removeExe
if($LASTEXITCODE -ne 0){throw 'Actual framework file removal test failed to compile.'}
& $removeExe $out
if($LASTEXITCODE -ne 0){throw "Actual readonly owned/unowned file cleanup failed case $LASTEXITCODE"}
[ordered]@{result='PASS';usb_access=$false;framework_fragment_executed=$true;retention_and_state_cases=15;actual_readonly_owned_spool_removed=$true;prefix_collision_unowned_readonly_file_preserved=$true;architecture_checks=$results;test_source_sha256=(Get-FileHash -LiteralPath $file).Hash;file_removal_test_source_sha256=(Get-FileHash -LiteralPath $removeFile).Hash} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $out 'results.json') -Encoding utf8NoBOM
Write-Output (Join-Path $out 'results.json')
