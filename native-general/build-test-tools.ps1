# SPDX-License-Identifier: Apache-2.0
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$zig=Join-Path $root '.tools/zig-x86_64-windows-0.15.2/zig.exe'
$env:ZIG_GLOBAL_CACHE_DIR=Join-Path $root '.cache/zig-global'
$env:ZIG_LOCAL_CACHE_DIR=Join-Path $root '.cache/zig-local'
$out=Join-Path $root 'build/general/test-tools'
New-Item -ItemType Directory -Force $out | Out-Null
& $zig cc -target x86_64-windows-gnu -std=c11 -O1 -Wall -Wextra -Werror -municode (Join-Path $PSScriptRoot 'test-sender-stub.c') -lbcrypt -o (Join-Path $out 'SCX4200-Test-Sender.exe')
if($LASTEXITCODE -ne 0){throw 'Streaming sender stub build failed'}
& $zig cc -target x86_64-windows-gnu -std=c11 -O2 -Wall -Wextra -Werror -municode (Join-Path $PSScriptRoot 'sender-stream-tests.c') -lsetupapi -lbcrypt -o (Join-Path $root 'build/general/x64/sender-stream-tests.exe')
if($LASTEXITCODE -ne 0){throw 'Streaming sender harness build failed'}
