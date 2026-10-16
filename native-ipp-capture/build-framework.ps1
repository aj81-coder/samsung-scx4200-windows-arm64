# SPDX-License-Identifier: Apache-2.0
param([ValidateSet('x64','arm64')][string]$Architecture='x64')
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$zig=Join-Path $root '.tools/zig-x86_64-windows-0.15.2/zig.exe'
$env:ZIG_GLOBAL_CACHE_DIR=Join-Path $root '.cache/zig-global'
$env:ZIG_LOCAL_CACHE_DIR=Join-Path $root '.cache/zig-local'
$cups=Join-Path $root 'build/cups-2.4.11'
$pappl=Join-Path $root 'build/pappl-1.4.10'
$out=Join-Path $root ('build/ipp/'+$Architecture)
$config=Join-Path $out 'pappl-config'
New-Item -ItemType Directory -Force $config | Out-Null
$header=Get-Content (Join-Path $pappl 'vcnet/config.h') -Raw
$header=$header -replace 'typedef unsigned long useconds_t;', '#include <sys/types.h>'
$header=$header -replace '(?m)^#\s*define [FRWX]_OK\s+\d+\s*$', ''
foreach($feature in @('HAVE_OPENSSL','HAVE_DNSSD','HAVE_MDNSRESPONDER','HAVE_LIBJPEG','HAVE_LIBPNG')) {
  $header=$header -replace ('(?m)^#define '+$feature+' 1\s*$'), ('/* '+$feature+' disabled: loopback capture build */')
}
Set-Content (Join-Path $config 'config.h') $header
[xml]$project=Get-Content (Join-Path $pappl 'vcnet/libpappl1.vcxproj')
$sources=@($project.Project.ItemGroup.ClCompile.Include | Where-Object { $_ -and $_ -ne 'dns_sd.c' } | ForEach-Object { Join-Path (Join-Path $pappl 'vcnet') $_ })
$thread=Get-Content (Join-Path $pappl 'pappl/win32-pthread.c') -Raw
$thread=$thread.Replace('(LPTHREAD_START_ROUTINE)pthread_wrapper','(unsigned (__stdcall *)(void *))pthread_wrapper')
Set-Content (Join-Path $config 'win32-pthread.c') $thread
$sources=@($sources | Where-Object { (Split-Path $_ -Leaf) -ne 'win32-pthread.c' }) + (Join-Path $config 'win32-pthread.c')
$accessors=Get-Content (Join-Path $pappl 'pappl/system-accessors.c') -Raw
$accessors=$accessors.Replace('cupsSetServerCredentials(NULL, system->hostname, 1);','/* TLS credentials excluded in this loopback-only, NO_TLS capture build. */')
Set-Content (Join-Path $config 'system-accessors.c') $accessors
$sources=@($sources | Where-Object { (Split-Path $_ -Leaf) -ne 'system-accessors.c' }) + (Join-Path $config 'system-accessors.c')
& (Join-Path $PSScriptRoot 'prepare-capture-guards.ps1') -PapplSource $pappl -OutputDirectory $config
$sources=@($sources | Where-Object { (Split-Path $_ -Leaf) -notin @('job-ipp.c','job-process.c') }) + (Join-Path $config 'job-ipp.c') + (Join-Path $config 'job-process.c')
$target=if($Architecture -eq 'arm64'){'aarch64-windows-gnu'}else{'x86_64-windows-gnu'}
$argsList=@('build-lib','-target',$target,'-O','ReleaseFast','-lc','-DWIN32','-I',$config,'-I',$cups,'-I',$pappl,'-I',(Join-Path $pappl 'pappl'),'-cflags','-std=gnu11','--')
$argsList += $sources
$argsList += @('-femit-bin='+(Join-Path $out 'pappl.lib'))
& $zig @argsList
if($LASTEXITCODE -ne 0){throw 'PAPPL framework build failed'}
Get-FileHash (Join-Path $out 'pappl.lib')

