# SPDX-License-Identifier: Apache-2.0
param([ValidateSet('x64','arm64')][string]$Architecture='x64')
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$zig=Join-Path $root '.tools/zig-x86_64-windows-0.15.2/zig.exe'
$env:ZIG_GLOBAL_CACHE_DIR=Join-Path $root '.cache/zig-global'
$env:ZIG_LOCAL_CACHE_DIR=Join-Path $root '.cache/zig-local'
$cups=Join-Path $root 'build/cups-2.4.11'
$zlib=Join-Path $root 'build/zlib-1.3.1'
if((Get-FileHash (Join-Path $root 'build/zlib-1.3.1.tar.gz')).Hash -ne '9A93B2B7DFDAC77CEBA5A558A580E74667DD6FEDE4585B91EEFB60F03B72DF23'){throw 'Unexpected zlib archive'}
$out=Join-Path $root ('build/ipp/'+$Architecture)
$config=Join-Path $out 'cups-config'
New-Item -ItemType Directory -Force $config | Out-Null
$header=Get-Content (Join-Path $cups 'vcnet/config.h') -Raw
$header=$header -replace 'typedef unsigned long useconds_t;', '#include <sys/types.h>'
$header=$header -replace '(?m)^#\s*define [FRW]_OK\s+\d+\s*$', ''
foreach($feature in @('HAVE_TLS','HAVE_OPENSSL','HAVE_DNSSD','HAVE_MDNSRESPONDER')) {
  $header=$header -replace ('(?m)^#define '+$feature+' 1\s*$'), ('/* '+$feature+' disabled: loopback capture build */')
}
Set-Content (Join-Path $config 'config.h') $header
[xml]$project=Get-Content (Join-Path $cups 'vcnet/libcups2.vcxproj')
$sources=@($project.Project.ItemGroup.ClCompile.Include | Where-Object { $_ } | ForEach-Object { Join-Path (Join-Path $cups 'vcnet') $_ })
$thread=Get-Content (Join-Path $cups 'cups/thread.c') -Raw
$thread=$thread.Replace('(LPTHREAD_START_ROUTINE)func','(unsigned (__stdcall *)(void *))func')
Set-Content (Join-Path $config 'thread.c') $thread
$sources=@($sources | Where-Object { (Split-Path $_ -Leaf) -ne 'thread.c' }) + (Join-Path $config 'thread.c')
$hash=Get-Content (Join-Path $cups 'cups/hash.c') -Raw
$hash=$hash.Replace('#include "cups-private.h"', "#include `"cups-private.h`"`n#include `"debug-internal.h`"")
Set-Content (Join-Path $config 'hash.c') $hash
$sources=@($sources | Where-Object { (Split-Path $_ -Leaf) -ne 'hash.c' }) + (Join-Path $config 'hash.c')
$sources += @('regcomp.c','regerror.c','regexec.c','regfree.c','split.c') | ForEach-Object { Join-Path (Join-Path $cups 'vcnet/regex') $_ }
& (Join-Path $PSScriptRoot 'prepare-decoder-guards.ps1') -CupsSource $cups -OutputDirectory $config
$sources=@($sources | Where-Object { (Split-Path $_ -Leaf) -ne 'raster-stream.c' }) + (Join-Path $config 'raster-stream.c')
$sources += @('adler32.c','compress.c','crc32.c','deflate.c','gzclose.c','gzlib.c','gzread.c','gzwrite.c','inflate.c','infback.c','inftrees.c','inffast.c','trees.c','uncompr.c','zutil.c') | ForEach-Object { Join-Path $zlib $_ }
$target=if($Architecture -eq 'arm64'){'aarch64-windows-gnu'}else{'x86_64-windows-gnu'}
$library=Join-Path $out 'cups-import.lib'
$argsList=@('build-lib','-dynamic','-rdynamic',('-femit-implib='+$library),'-target',$target,'-O','ReleaseFast','-lc','-lws2_32','-ladvapi32','-lbcrypt','-DWIN32','-I',$config,'-I',$cups,'-I',$zlib,'-I',(Join-Path $cups 'cups'),'-I',(Join-Path $cups 'vcnet/regex'),'-cflags','-std=gnu11','-Wno-deprecated-declarations','--')
$argsList += $sources
$argsList += @('-femit-bin='+(Join-Path $out 'cups.dll'))
& $zig @argsList
if($LASTEXITCODE -ne 0){throw 'CUPS dependency build failed'}
& $zig cc -target $target -O1 -I $cups (Join-Path $PSScriptRoot 'dependency-check.c') $library -lws2_32 -ladvapi32 -lbcrypt -ldbghelp -o (Join-Path $out 'cups-check.exe')
if($LASTEXITCODE -ne 0){throw 'CUPS dependency check link failed'}
Get-FileHash (Join-Path $out 'cups-check.exe')

