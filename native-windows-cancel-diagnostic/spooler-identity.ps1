# SPDX-License-Identifier: Apache-2.0
# Query-only, Windows PowerShell 5.1 / ARM64-compatible process identity probe.
function Initialize-ScxIdentityNative {
if (-not ('Scx4200Identity.Probe' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace Scx4200Identity {
    public sealed class Result {
        public bool success;
        public string stage;
        public int win32_error;
        public uint service_state;
        public uint process_id;
        public ulong creation_filetime;
        public string identity;
        public string method = "SCM_QUERY_STATUS_PROCESS_QUERY_LIMITED_INFORMATION_GetProcessTimes";
    }
    [StructLayout(LayoutKind.Sequential)]
    public struct ServiceStatus {
        public uint type, state, controls, exitCode, serviceExitCode, checkpoint, waitHint, pid, flags;
    }
    // Small boundary permits device-free tests of cleanup, identity races and denial.
    public interface IApi {
        IntPtr Manager(out int error);
        IntPtr Service(IntPtr manager, out int error);
        bool Status(IntPtr service, out ServiceStatus status, out int error);
        IntPtr Process(uint pid, out int error);
        bool Creation(IntPtr process, out ulong creation, out int error);
        void CloseService(IntPtr handle);
        void CloseProcess(IntPtr handle);
    }
    internal sealed class WindowsApi : IApi {
        [StructLayout(LayoutKind.Sequential)] struct Ft { public uint low, high; }
        [DllImport("advapi32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
        static extern IntPtr OpenSCManager(string machine, string database, uint access);
        [DllImport("advapi32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
        static extern IntPtr OpenService(IntPtr manager, string name, uint access);
        [DllImport("advapi32.dll", SetLastError=true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        static extern bool QueryServiceStatusEx(IntPtr service, int info, out ServiceStatus status, uint size, out uint needed);
        [DllImport("advapi32.dll")] static extern bool CloseServiceHandle(IntPtr handle);
        [DllImport("kernel32.dll", SetLastError=true)]
        static extern IntPtr OpenProcess(uint access, [MarshalAs(UnmanagedType.Bool)] bool inherit, uint pid);
        [DllImport("kernel32.dll", SetLastError=true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        static extern bool GetProcessTimes(IntPtr process, out Ft creation, out Ft exit, out Ft kernel, out Ft user);
        [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
        public IntPtr Manager(out int error) { IntPtr h=OpenSCManager(null,null,1); error=h==IntPtr.Zero?Marshal.GetLastWin32Error():0; return h; }
        public IntPtr Service(IntPtr manager, out int error) { IntPtr h=OpenService(manager,"Spooler",4); error=h==IntPtr.Zero?Marshal.GetLastWin32Error():0; return h; }
        public bool Status(IntPtr service,out ServiceStatus status,out int error) {
            uint needed; bool ok=QueryServiceStatusEx(service,0,out status,(uint)Marshal.SizeOf(typeof(ServiceStatus)),out needed);
            error=ok?0:Marshal.GetLastWin32Error(); return ok;
        }
        public IntPtr Process(uint pid,out int error) { IntPtr h=OpenProcess(0x1000,false,pid); error=h==IntPtr.Zero?Marshal.GetLastWin32Error():0; return h; }
        public bool Creation(IntPtr process,out ulong creation,out int error) {
            Ft c,e,k,u; bool ok=GetProcessTimes(process,out c,out e,out k,out u);
            error=ok?0:Marshal.GetLastWin32Error(); creation=((ulong)c.high<<32)|c.low; return ok;
        }
        public void CloseService(IntPtr handle) { CloseServiceHandle(handle); }
        public void CloseProcess(IntPtr handle) { CloseHandle(handle); }
    }
    public static class Probe {
        static Result Fail(Result result,string stage,int error) { result.stage=stage; result.win32_error=error; return result; }
        public static Result Spooler() { return Spooler(new WindowsApi()); }
        public static Result StatusOnly() { return StatusOnly(new WindowsApi()); }
        public static Result StatusOnly(IApi api) {
            Result r=new Result(); r.method="SCM_QUERY_STATUS";
            IntPtr manager=IntPtr.Zero, service=IntPtr.Zero;
            try {
                int error; manager=api.Manager(out error);
                if(manager==IntPtr.Zero) return Fail(r,"OpenSCManager",error);
                service=api.Service(manager,out error);
                if(service==IntPtr.Zero) return Fail(r,"OpenService",error);
                ServiceStatus status;
                if(!api.Status(service,out status,out error)) return Fail(r,"QueryServiceStatusEx",error);
                r.service_state=status.state; r.process_id=status.pid;
                if(status.state!=4 || status.pid==0) return Fail(r,"ServiceNotRunning",0);
                r.stage="ServiceStatusVerified"; r.success=true; return r;
            } finally {
                if(service!=IntPtr.Zero) api.CloseService(service);
                if(manager!=IntPtr.Zero) api.CloseService(manager);
            }
        }
        public static Result Spooler(IApi api) {
            Result r=new Result(); IntPtr manager=IntPtr.Zero,service=IntPtr.Zero,process=IntPtr.Zero;
            try {
                int error; manager=api.Manager(out error);
                if(manager==IntPtr.Zero) return Fail(r,"OpenSCManager",error);
                service=api.Service(manager,out error);
                if(service==IntPtr.Zero) return Fail(r,"OpenService",error);
                ServiceStatus before;
                if(!api.Status(service,out before,out error)) return Fail(r,"QueryServiceStatusEx",error);
                r.service_state=before.state; r.process_id=before.pid;
                if(before.state!=4 || before.pid==0) return Fail(r,"ServiceNotRunning",0);
                process=api.Process(before.pid,out error);
                if(process==IntPtr.Zero) return Fail(r,"OpenProcess",error);
                ulong creation;
                if(!api.Creation(process,out creation,out error)) return Fail(r,"GetProcessTimes",error);
                if(creation==0) return Fail(r,"InvalidCreationTime",0);
                ServiceStatus after;
                if(!api.Status(service,out after,out error)) return Fail(r,"RecheckServiceStatus",error);
                if(after.state!=4 || after.pid!=before.pid) return Fail(r,"ServiceIdentityChanged",0);
                r.creation_filetime=creation; r.identity=before.pid.ToString(System.Globalization.CultureInfo.InvariantCulture)+":"+creation.ToString(System.Globalization.CultureInfo.InvariantCulture);
                r.stage="Verified"; r.success=true; return r;
            } finally {
                if(process!=IntPtr.Zero) api.CloseProcess(process);
                if(service!=IntPtr.Zero) api.CloseService(service);
                if(manager!=IntPtr.Zero) api.CloseService(manager);
            }
        }
        public static Result CurrentProcess() {
            IApi api=new WindowsApi(); Result r=new Result(); r.method="PROCESS_QUERY_LIMITED_INFORMATION_GetProcessTimes";
            r.process_id=(uint)System.Diagnostics.Process.GetCurrentProcess().Id;
            int error; IntPtr process=api.Process(r.process_id,out error);
            if(process==IntPtr.Zero) return Fail(r,"OpenProcess",error);
            try {
                ulong creation;
                if(!api.Creation(process,out creation,out error)) return Fail(r,"GetProcessTimes",error);
                if(creation==0) return Fail(r,"InvalidCreationTime",0);
                r.creation_filetime=creation; r.identity=r.process_id.ToString()+":"+creation.ToString();
                r.stage="Verified"; r.success=true; return r;
            } finally { api.CloseProcess(process); }
        }
    }
}
'@
}
}

function ConvertTo-ScxIdentityResult($value) {
    # Explicit fields prevent native exceptions or machine paths entering reports.
    return [pscustomobject]@{
        success=[bool]$value.success; stage=[string]$value.stage; win32_error=[int]$value.win32_error
        service_state=[uint32]$value.service_state; process_id=[uint32]$value.process_id
        creation_filetime=[string]$value.creation_filetime; identity=[string]$value.identity
        method=[string]$value.method
    }
}
function Get-ScxSpoolerIdentity {
    $stage='InitializeNativeProbe'
    try {
        Initialize-ScxIdentityNative
        $stage='NativeProbeException'
        $result=ConvertTo-ScxIdentityResult ([Scx4200Identity.Probe]::Spooler())
        if (!$result.success -and $result.stage -eq 'OpenProcess' -and $result.win32_error -eq 5) {
            return Get-ScxWmiSpoolerIdentity $result
        }
        return $result
    } catch { return New-ScxIdentityProbeFailure $stage }
}
function Get-ScxNativeSpoolerStatus {
    return ConvertTo-ScxIdentityResult ([Scx4200Identity.Probe]::StatusOnly())
}
function Get-ScxWmiProcessCreation([uint32]$processId) {
    $rows=@(Get-CimInstance Win32_Process -Filter ('ProcessId='+$processId.ToString([Globalization.CultureInfo]::InvariantCulture)) -Property ProcessId,CreationDate -OperationTimeoutSec 5 -ErrorAction Stop)
    if($rows.Count -ne 1 -or [uint32]$rows[0].ProcessId -ne $processId -or $null -eq $rows[0].CreationDate) { throw 'Invalid process creation record' }
    if($rows[0].CreationDate -isnot [DateTime]) { throw 'Invalid process creation date type' }
    $created=[DateTime]$rows[0].CreationDate
    if($created -lt [DateTime]'2000-01-01' -or $created.ToUniversalTime() -gt [DateTime]::UtcNow.AddMinutes(1)) { throw 'Invalid process creation date value' }
    return $created.ToUniversalTime().ToFileTimeUtc().ToString([Globalization.CultureInfo]::InvariantCulture)
}
function Get-ScxWmiSpoolerIdentity($initial) {
    $result=[pscustomobject]@{
        success=$false; stage='WmiProcessCreation'; win32_error=0
        service_state=$initial.service_state; process_id=$initial.process_id
        creation_filetime='0'; identity=''; method='SCM_QUERY_STATUS_WMI_PROCESS_CREATION'
        native_probe_stage=$initial.stage; native_probe_win32_error=$initial.win32_error
        query_exception_type=$null; query_hresult=$null
    }
    try {
        $first=Get-ScxWmiProcessCreation $initial.process_id
        $result.stage='WmiProcessCreationRecheck'
        $second=Get-ScxWmiProcessCreation $initial.process_id
        if($first -ne $second) { $result.stage='WmiProcessIdentityChanged'; return $result }
        $result.stage='WmiServiceRecheck'
        $service=Get-ScxNativeSpoolerStatus
        if(!$service.success) { $result.win32_error=$service.win32_error; return $result }
        if($service.service_state -ne 4 -or $service.process_id -ne $initial.process_id) { $result.stage='WmiServiceIdentityChanged'; return $result }
        $result.creation_filetime=$first; $result.identity=([string]$initial.process_id+':'+$first)
        $result.success=$true; $result.stage='Verified'; return $result
    } catch {
        $result.query_exception_type=$_.Exception.GetType().FullName
        $result.query_hresult=[int]$_.Exception.HResult
        return $result
    }
}
function Get-ScxCurrentProcessIdentity {
    $stage='InitializeNativeProbe'
    try {
        Initialize-ScxIdentityNative
        $stage='NativeProbeException'
        return ConvertTo-ScxIdentityResult ([Scx4200Identity.Probe]::CurrentProcess())
    } catch { return New-ScxIdentityProbeFailure $stage }
}
function New-ScxIdentityProbeFailure([string]$stage) {
    return [pscustomobject]@{
        success=$false; stage=$stage; win32_error=0; service_state=0; process_id=0
        creation_filetime='0'; identity=''; method='NativeQueryOnlyIdentityProbe'
    }
}
