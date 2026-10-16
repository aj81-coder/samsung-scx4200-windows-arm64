// SPDX-License-Identifier: Apache-2.0
#ifndef UNICODE
#define UNICODE
#endif
#ifndef _UNICODE
#define _UNICODE
#endif
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <shellapi.h>
#include <wchar.h>
#include <stdio.h>

#define TRAY_MESSAGE (WM_APP + 1)
#define CMD_STATUS 1001
#define CMD_LOGS 1002
#define CMD_QUIT 1003
#define CMD_START 1004
#define CMD_STOP 1005
#define CMD_CANCEL 1006
#define CMD_RECOVER 1007
#define CMD_DIAGNOSTICS 1008
static HWND window;
static NOTIFYICONDATAW icon;
static PROCESS_INFORMATION child;
static HANDLE instance, child_job, control_process;
static wchar_t data_dir[32768], executable[32768], status_text[256];
static BOOL quitting, stopping, tray_added, was_ready;
static BOOL housekeeping, deferred_start;
static BOOL launch_bridge_core(void);
static DWORD quit_started;
static UINT taskbar_created;
static BOOL tray_icon_owned;
/* SHGetStockIconInfo returns a caller-owned icon. Keep a shared fallback only
 * when Windows cannot supply its standard printer image. */
static HICON load_printer_icon(void) {
 SHSTOCKICONINFO info;ZeroMemory(&info,sizeof(info));info.cbSize=sizeof(info);
 if(SUCCEEDED(SHGetStockIconInfo(SIID_PRINTER,SHGSI_ICON|SHGSI_SMALLICON,&info)) && info.hIcon) {
  tray_icon_owned=TRUE;return info.hIcon;
 }
 return LoadIconW(NULL,IDI_APPLICATION);
}

static void show_error(const wchar_t *text) {
 MessageBoxW(window,text,L"Samsung SCX-4200",MB_OK|MB_ICONWARNING);
}
static void set_status(const wchar_t *text) {
 if(!wcscmp(status_text,text))return;
 wcscpy_s(status_text,256,text);
 wcsncpy_s(icon.szTip,128,text,_TRUNCATE);
 if(tray_added)Shell_NotifyIconW(NIM_MODIFY,&icon);
}
static BOOL combine(wchar_t *out,size_t count,const wchar_t *directory,const wchar_t *leaf) {
 return _snwprintf_s(out,count,_TRUNCATE,L"%s\\%s",directory,leaf)>0;
}
/* A persistent, local data directory is mandatory. Reject reparse points
 * throughout its ancestry so lock/report files cannot silently be redirected. */
static BOOL prepare_data_directory(const wchar_t *input) {
 if(wcslen(input)<4 || !((input[0]>=L'A' && input[0]<=L'Z')||(input[0]>=L'a' && input[0]<=L'z')) || input[1]!=L':' || input[2]!=L'\\' || wcschr(input,L'"'))return FALSE;
 DWORD n=GetFullPathNameW(input,32768,data_dir,NULL);
 if(!n || n>=32768 || wcslen(data_dir)<=3 || wcschr(data_dir+2,L':'))return FALSE;
 size_t length=wcslen(data_dir);
 while(length>3 && data_dir[length-1]==L'\\')data_dir[--length]=0;
 wchar_t drive[4]={data_dir[0],L':',L'\\',0};
 if(GetDriveTypeW(drive)!=DRIVE_FIXED)return FALSE;
 for(size_t i=3;i<=length;i++) {
  if(data_dir[i] && data_dir[i]!=L'\\')continue;
  wchar_t saved=data_dir[i];data_dir[i]=0;
  DWORD attributes=GetFileAttributesW(data_dir);
  if(attributes==INVALID_FILE_ATTRIBUTES) {
   DWORD error=GetLastError();
   if((error!=ERROR_FILE_NOT_FOUND && error!=ERROR_PATH_NOT_FOUND) || !CreateDirectoryW(data_dir,NULL)){data_dir[i]=saved;return FALSE;}
   attributes=GetFileAttributesW(data_dir);
  }
  data_dir[i]=saved;
  if(attributes==INVALID_FILE_ATTRIBUTES || !(attributes&FILE_ATTRIBUTE_DIRECTORY) || (attributes&FILE_ATTRIBUTE_REPARSE_POINT))return FALSE;
 }
 return TRUE;
}
static BOOL named_lock(const wchar_t *name) {
 wchar_t path[32768];
 if(!combine(path,32768,data_dir,name))return TRUE;
 if(GetFileAttributesW(path)!=INVALID_FILE_ATTRIBUTES)return TRUE;
 DWORD error=GetLastError();
 return error!=ERROR_FILE_NOT_FOUND && error!=ERROR_PATH_NOT_FOUND;
}
static BOOL recovery_lock(void) {return named_lock(L"SESSION-ACTIVE.lock");}
static BOOL control_active(void) {
 if(control_process && WaitForSingleObject(control_process,0)==WAIT_OBJECT_0) {
  DWORD code=1;GetExitCodeProcess(control_process,&code);CloseHandle(control_process);control_process=NULL;
  if(housekeeping) {
   BOOL start=deferred_start;housekeeping=FALSE;deferred_start=FALSE;
   if(quitting){DestroyWindow(window);return FALSE;}
   if(code)set_status(L"SCX-4200: housekeeping refused; check logs; choose Start printing");
   else if(start && !launch_bridge_core())set_status(L"SCX-4200: could not start; check locks and installation");
   else if(!start)set_status(L"SCX-4200: stopped; choose Start printing");
  } else {
   if(!child.hProcess)set_status(recovery_lock()?L"SCX-4200: stopped; recovery required":L"SCX-4200: stopped; choose Start printing");
   if(code)show_error(L"The control process failed. No successful cancellation or recovery is confirmed. Check the installation and logs.");
  }
 }
 return control_process || named_lock(L"CONTROL-ACTIVE.lock");
}
static BOOL launch_control(const wchar_t *action) {
 if(control_active() || quitting){show_error(L"A control operation is already active. Finish it before another action.");return FALSE;}
 if(!wcscmp(action,L"Recover") && child.hProcess){show_error(L"Use Stop printing and wait for the engine to stop before recovery.");return FALSE;}
 wchar_t system[32768],power[32768],script[32768],command[32768];
 UINT n=GetSystemDirectoryW(system,32768);
 if(!n || n>=32768 || !combine(power,32768,system,L"WindowsPowerShell\\v1.0\\powershell.exe") || !combine(script,32768,executable,L"controls.ps1"))return FALSE;
 if(_snwprintf_s(command,32768,_TRUNCATE,L"\"%s\" -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File \"%s\" -DataDir \"%s\" -Action %s",power,script,data_dir,action)<0)return FALSE;
 STARTUPINFOW startup;PROCESS_INFORMATION process;ZeroMemory(&startup,sizeof(startup));ZeroMemory(&process,sizeof(process));startup.cb=sizeof(startup);
 if(!CreateProcessW(power,command,NULL,NULL,FALSE,CREATE_NO_WINDOW,NULL,data_dir,&startup,&process)){show_error(L"The control window could not be started. Check the installation.");return FALSE;}
 CloseHandle(process.hThread);control_process=process.hProcess;return TRUE;
}
static HANDLE child_event(const wchar_t *kind,DWORD access) {
 wchar_t name[128];
 _snwprintf_s(name,128,_TRUNCATE,L"Local\\SCX4200.%s.%lu",kind,child.dwProcessId);
 return OpenEventW(access,FALSE,name);
}
static BOOL request_stop(void) {
 HANDLE event=child_event(L"Stop",EVENT_MODIFY_STATE);
 if(!event)return FALSE;
 BOOL ok=SetEvent(event);CloseHandle(event);return ok;
}
static BOOL launch_bridge_core(void) {
 if(child.hProcess || control_active() || recovery_lock())return FALSE;
 was_ready=FALSE;stopping=FALSE;
 wchar_t bridge[32768],log_path[32768],command[32768];
 if(!combine(bridge,32768,executable,L"SCX4200-Reliable-Bridge.exe"))return FALSE;
 DWORD attributes=GetFileAttributesW(bridge);
 if(attributes==INVALID_FILE_ATTRIBUTES || (attributes&(FILE_ATTRIBUTE_DIRECTORY|FILE_ATTRIBUTE_REPARSE_POINT)))return FALSE;
 SYSTEMTIME now;GetSystemTime(&now);
 wchar_t leaf[128];
 _snwprintf_s(leaf,128,_TRUNCATE,L"background-%04u%02u%02u-%02u%02u%02u-%lu-%lu.log",now.wYear,now.wMonth,now.wDay,now.wHour,now.wMinute,now.wSecond,GetCurrentProcessId(),GetTickCount());
 if(!combine(log_path,32768,data_dir,leaf))return FALSE;
 SECURITY_ATTRIBUTES security={sizeof(security),NULL,TRUE};
 HANDLE log=CreateFileW(log_path,GENERIC_WRITE,FILE_SHARE_READ,&security,CREATE_NEW,FILE_ATTRIBUTE_NORMAL,NULL);
 if(log==INVALID_HANDLE_VALUE)return FALSE;
 HANDLE input=CreateFileW(L"NUL",GENERIC_READ,FILE_SHARE_READ|FILE_SHARE_WRITE,&security,OPEN_EXISTING,FILE_ATTRIBUTE_NORMAL,NULL);
 if(input==INVALID_HANDLE_VALUE){CloseHandle(log);return FALSE;}
 if(_snwprintf_s(command,32768,_TRUNCATE,L"\"%s\" --background",bridge)<0){CloseHandle(input);CloseHandle(log);return FALSE;}
 STARTUPINFOEXW startup;ZeroMemory(&startup,sizeof(startup));startup.StartupInfo.cb=sizeof(startup);
 startup.StartupInfo.dwFlags=STARTF_USESTDHANDLES;startup.StartupInfo.hStdInput=input;startup.StartupInfo.hStdOutput=log;startup.StartupInfo.hStdError=log;
 SIZE_T bytes=0;InitializeProcThreadAttributeList(NULL,1,0,&bytes);
 startup.lpAttributeList=HeapAlloc(GetProcessHeap(),0,bytes);
 BOOL ok=FALSE,initialized=FALSE;
 HANDLE job=CreateJobObjectW(NULL,NULL);
 JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits;ZeroMemory(&limits,sizeof(limits));
 limits.BasicLimitInformation.LimitFlags=JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
 BOOL job_ready=job && SetInformationJobObject(job,JobObjectExtendedLimitInformation,&limits,sizeof(limits));
 HANDLE inherited[2]={input,log};
 if(job_ready && startup.lpAttributeList && InitializeProcThreadAttributeList(startup.lpAttributeList,1,0,&bytes)) {
  initialized=TRUE;
  if(UpdateProcThreadAttribute(startup.lpAttributeList,0,PROC_THREAD_ATTRIBUTE_HANDLE_LIST,inherited,sizeof(inherited),NULL,NULL))
   ok=CreateProcessW(bridge,command,NULL,NULL,TRUE,CREATE_SUSPENDED|CREATE_NO_WINDOW|EXTENDED_STARTUPINFO_PRESENT,NULL,data_dir,&startup.StartupInfo,&child);
 }
 if(initialized)DeleteProcThreadAttributeList(startup.lpAttributeList);
 if(startup.lpAttributeList)HeapFree(GetProcessHeap(),0,startup.lpAttributeList);
 CloseHandle(input);CloseHandle(log);
 if(ok) {
  /* The child cannot run or create a printer session until ownership is set.
   * An unexpected host exit closes this non-inherited job handle and kills
   * the bridge tree, leaving its durable session lock for explicit recovery. */
  if(!AssignProcessToJobObject(job,child.hProcess) || ResumeThread(child.hThread)==(DWORD)-1) {
   TerminateProcess(child.hProcess,1);WaitForSingleObject(child.hProcess,INFINITE);
   CloseHandle(child.hThread);CloseHandle(child.hProcess);ZeroMemory(&child,sizeof(child));ok=FALSE;
  } else {CloseHandle(child.hThread);child.hThread=NULL;child_job=job;job=NULL;}
 }
 if(job)CloseHandle(job);
 return ok;
}
/* Cleanup is asynchronous and gated before every engine start. Its guard and
 * report belong to the helper. Refusal never causes an automatic restart. The
 * helper is outside the engine kill-on-close job so Quit cannot interrupt it. */
static BOOL launch_bridge(void) {
 if(control_active() || quitting || child.hProcess || recovery_lock())return FALSE;
 wchar_t system[32768],power[32768],script[32768],command[32768];
 UINT n=GetSystemDirectoryW(system,32768);
 if(!n || n>=32768 || !combine(power,32768,system,L"WindowsPowerShell\\v1.0\\powershell.exe") || !combine(script,32768,executable,L"housekeeping.ps1"))return FALSE;
 DWORD attributes=GetFileAttributesW(script);
 if(attributes==INVALID_FILE_ATTRIBUTES || (attributes&(FILE_ATTRIBUTE_DIRECTORY|FILE_ATTRIBUTE_REPARSE_POINT)))return FALSE;
 if(_snwprintf_s(command,32768,_TRUNCATE,L"\"%s\" -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File \"%s\" -DataDir \"%s\"",power,script,data_dir)<0)return FALSE;
 STARTUPINFOW startup;PROCESS_INFORMATION process;ZeroMemory(&startup,sizeof(startup));ZeroMemory(&process,sizeof(process));startup.cb=sizeof(startup);
 if(!CreateProcessW(power,command,NULL,NULL,FALSE,CREATE_NO_WINDOW,NULL,data_dir,&startup,&process))return FALSE;
 CloseHandle(process.hThread);control_process=process.hProcess;housekeeping=TRUE;deferred_start=TRUE;
 set_status(L"SCX-4200: preparing recent history...");return TRUE;
}
static void quit(void) {
 if(housekeeping){quitting=TRUE;deferred_start=FALSE;set_status(L"SCX-4200: finishing housekeeping before exit...");control_active();return;}
 if(control_active()){show_error(L"Finish the active cancellation or recovery window before quitting.");return;}
 if(!child.hProcess){DestroyWindow(window);return;}
 if(quitting)return;
 quitting=TRUE;stopping=TRUE;quit_started=GetTickCount();request_stop();
 set_status(L"SCX-4200: stopping safely...");
}
static void update_child(void) {
 control_active();
 if(!child.hProcess)return;
 if(WaitForSingleObject(child.hProcess,0)==WAIT_OBJECT_0) {
  DWORD code=1;GetExitCodeProcess(child.hProcess,&code);CloseHandle(child.hProcess);child.hProcess=NULL;
  if(child_job){CloseHandle(child_job);child_job=NULL;}
  stopping=FALSE;
  if(quitting){DestroyWindow(window);return;}
  set_status(recovery_lock()?L"SCX-4200: stopped; recovery required":code?L"SCX-4200: stopped; check logs":L"SCX-4200: stopped");
  return;
 }
 if(quitting) {
  request_stop();
  if(GetTickCount()-quit_started>60000) {
   quitting=FALSE;
   set_status(L"SCX-4200: still stopping; check logs");
   show_error(L"The bridge has not stopped yet. It has not been forcibly terminated. Please allow the current operation to finish and check the logs before trying Quit again.");
  }
  return;
 }
 if(stopping){request_stop();set_status(L"SCX-4200: stopping safely...");return;}
 HANDLE ready=child_event(L"Ready",SYNCHRONIZE);
 BOOL signaled=ready && WaitForSingleObject(ready,0)==WAIT_OBJECT_0;
 if(ready)CloseHandle(ready);
 if(signaled)was_ready=TRUE;
 set_status(signaled?L"SCX-4200: ready for documents":was_ready?L"SCX-4200: working or needs attention; check logs":L"SCX-4200: starting; check logs if this persists");
}
static LRESULT CALLBACK procedure(HWND hwnd,UINT message,WPARAM wparam,LPARAM lparam) {
 if(message==taskbar_created && tray_added){Shell_NotifyIconW(NIM_ADD,&icon);return 0;}
 switch(message) {
 case TRAY_MESSAGE:
  if(lparam==WM_LBUTTONDBLCLK){MessageBoxW(hwnd,status_text,L"Samsung SCX-4200",MB_OK);return 0;}
  if(lparam==WM_RBUTTONUP || lparam==WM_CONTEXTMENU) {
   POINT position;GetCursorPos(&position);HMENU menu=CreatePopupMenu();
   BOOL controlling=control_active();
   AppendMenuW(menu,MF_STRING|((child.hProcess || controlling || recovery_lock())?MF_GRAYED:0),CMD_START,L"Start printing");
   AppendMenuW(menu,MF_STRING|(((!child.hProcess && !housekeeping) || stopping)?MF_GRAYED:0),CMD_STOP,L"Stop printing");
   AppendMenuW(menu,MF_STRING|((!child.hProcess || stopping || controlling)?MF_GRAYED:0),CMD_CANCEL,L"Cancel current document");
   AppendMenuW(menu,MF_STRING|((child.hProcess || controlling || !recovery_lock())?MF_GRAYED:0),CMD_RECOVER,L"Recover stopped session");
   AppendMenuW(menu,MF_SEPARATOR,0,NULL);
   AppendMenuW(menu,MF_STRING|((controlling || quitting)?MF_GRAYED:0),CMD_DIAGNOSTICS,L"Save diagnostics");
   AppendMenuW(menu,MF_STRING,CMD_STATUS,L"Printer status");AppendMenuW(menu,MF_STRING,CMD_LOGS,L"Open logs folder");
   AppendMenuW(menu,MF_SEPARATOR,0,NULL);AppendMenuW(menu,MF_STRING,CMD_QUIT,L"Quit");
   SetForegroundWindow(hwnd);TrackPopupMenu(menu,TPM_RIGHTBUTTON,position.x,position.y,0,hwnd,NULL);DestroyMenu(menu);PostMessageW(hwnd,WM_NULL,0,0);
  }return 0;
 case WM_COMMAND:
  if(LOWORD(wparam)==CMD_QUIT)quit();
  else if(LOWORD(wparam)==CMD_START){BOOL active=control_active();if(child.hProcess || active || recovery_lock())show_error(L"Printing cannot start while an engine, control operation or unrecovered session is present.");else if(!launch_bridge())show_error(L"The print engine could not start. Check the installation.");}
  else if(LOWORD(wparam)==CMD_STOP){if(housekeeping){deferred_start=FALSE;set_status(L"SCX-4200: finishing housekeeping; printing stopped");}else if(child.hProcess){stopping=TRUE;request_stop();set_status(L"SCX-4200: stopping safely...");}}
  else if(LOWORD(wparam)==CMD_CANCEL){if(child.hProcess && !stopping)launch_control(L"Cancel");}
  else if(LOWORD(wparam)==CMD_RECOVER)launch_control(L"Recover");
  else if(LOWORD(wparam)==CMD_DIAGNOSTICS)launch_control(L"Diagnostics");
  else if(LOWORD(wparam)==CMD_LOGS)ShellExecuteW(hwnd,L"open",data_dir,NULL,NULL,SW_SHOWNORMAL);
  else if(LOWORD(wparam)==CMD_STATUS)MessageBoxW(hwnd,recovery_lock() && !child.hProcess?L"The previous session needs recovery. Do not restart or resend an uncertain document. Keep the printer queue installed. Choose Recover stopped session from the tray menu, then Start printing after recovery succeeds. Logs are available from the tray menu.":status_text,L"Samsung SCX-4200",MB_OK);
  return 0;
 case WM_TIMER:update_child();return 0;
 case WM_CLOSE:quit();return 0;
 case WM_QUERYENDSESSION:if(housekeeping){quitting=TRUE;deferred_start=FALSE;}if(child.hProcess){stopping=TRUE;request_stop();WaitForSingleObject(child.hProcess,3000);}return TRUE;
 case WM_ENDSESSION:if(wparam && child.hProcess)request_stop();return 0;
 case WM_DESTROY:if(tray_added)Shell_NotifyIconW(NIM_DELETE,&icon);if(tray_icon_owned && icon.hIcon){DestroyIcon(icon.hIcon);icon.hIcon=NULL;tray_icon_owned=FALSE;}PostQuitMessage(0);return 0;
 }
 return DefWindowProcW(hwnd,message,wparam,lparam);
}
int WINAPI wWinMain(HINSTANCE module,HINSTANCE previous,LPWSTR line,int show) {
 (void)previous;(void)line;(void)show;
 int argc=0;LPWSTR *argv=CommandLineToArgvW(GetCommandLineW(),&argc);
 BOOL check_only=argv && argc>1 && !wcscmp(argv[argc-1],L"--check-only");
 if(!argv || argc!=(check_only?4:3) || wcscmp(argv[1],L"--data-dir") || !prepare_data_directory(argv[2])) {
  if(argv)LocalFree(argv);if(!check_only)show_error(L"Start this application with --data-dir followed by an absolute folder on the laptop's internal drive. The folder must not use redirected or linked directories.");return 64;
 }
 LocalFree(argv);
 DWORD n=GetModuleFileNameW(NULL,executable,32768);
 if(!n || n>=32768)return 1;
 wchar_t *slash=wcsrchr(executable,L'\\');if(!slash)return 1;*slash=0;
 if(check_only)return 0;
 instance=CreateMutexW(NULL,TRUE,L"Local\\SCX4200.BackgroundHost");
 if(!instance || GetLastError()==ERROR_ALREADY_EXISTS){if(instance)CloseHandle(instance);show_error(L"The SCX-4200 background application is already running in this Windows session. Look for its icon beside the clock.");return 2;}
 WNDCLASSW cls;ZeroMemory(&cls,sizeof(cls));cls.lpfnWndProc=procedure;cls.hInstance=module;cls.lpszClassName=L"SCX4200.BackgroundHost.Window";
 if(!RegisterClassW(&cls)){CloseHandle(instance);return 1;}
 window=CreateWindowExW(0,cls.lpszClassName,L"Samsung SCX-4200",WS_OVERLAPPED,0,0,0,0,NULL,NULL,module,NULL);
 if(!window){CloseHandle(instance);return 1;}
 ZeroMemory(&icon,sizeof(icon));icon.cbSize=sizeof(icon);icon.hWnd=window;icon.uID=1;icon.uFlags=NIF_ICON|NIF_MESSAGE|NIF_TIP;icon.uCallbackMessage=TRAY_MESSAGE;icon.hIcon=load_printer_icon();
 wcscpy_s(status_text,256,L"SCX-4200: starting");wcscpy_s(icon.szTip,128,status_text);
 tray_added=Shell_NotifyIconW(NIM_ADD,&icon);taskbar_created=RegisterWindowMessageW(L"TaskbarCreated");
 if(!tray_added){DestroyWindow(window);CloseHandle(instance);return 1;}
 if(recovery_lock())set_status(L"SCX-4200: stopped; recovery required");
 else if(control_active())set_status(L"SCX-4200: control operation active; printing stopped");
 else if(!launch_bridge())set_status(L"SCX-4200: could not start; check installation");
 SetTimer(window,1,500,NULL);
 MSG message;while(GetMessageW(&message,NULL,0,0)>0){TranslateMessage(&message);DispatchMessageW(&message);}
 if(child_job)CloseHandle(child_job);
 if(control_process)CloseHandle(control_process);
 CloseHandle(instance);return 0;
}
