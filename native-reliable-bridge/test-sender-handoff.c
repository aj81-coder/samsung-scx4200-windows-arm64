// SPDX-License-Identifier: Apache-2.0
/* Device-free integration: exact bridge-style child launch, cancellation set
 * before launch so a genuine sender cannot enumerate or write USB. */
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
int wmain(int argc,wchar_t **argv) {
 if(argc!=6)return 64;
 SECURITY_ATTRIBUTES sa={sizeof(sa),NULL,TRUE};
 HANDLE permit=CreateEventW(&sa,TRUE,TRUE,NULL),cancel=CreateEventW(&sa,TRUE,TRUE,NULL);
 HANDLE owned=CreateJobObjectW(NULL,NULL);JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits={0};
 limits.BasicLimitInformation.LimitFlags=JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
 if(!permit || !cancel || !owned || !SetInformationJobObject(owned,JobObjectExtendedLimitInformation,&limits,sizeof(limits)))return 1;
 STARTUPINFOEXW si={0};PROCESS_INFORMATION pi={0};SIZE_T bytes=0;si.StartupInfo.cb=sizeof(si);
 InitializeProcThreadAttributeList(NULL,1,0,&bytes);si.lpAttributeList=HeapAlloc(GetProcessHeap(),0,bytes);
 if(!si.lpAttributeList || !InitializeProcThreadAttributeList(si.lpAttributeList,1,0,&bytes))return 1;
 HANDLE handles[2]={permit,cancel};
 if(!UpdateProcThreadAttribute(si.lpAttributeList,0,PROC_THREAD_ATTRIBUTE_HANDLE_LIST,handles,sizeof(handles),NULL,NULL))return 1;
 wchar_t command[65536];
 if(swprintf(command,65536,L"\"%ls\" --jobbundle \"%ls\" --sha256 %ls --permit-handle %llu --cancel-handle %llu --report \"%ls\" --progress \"%ls\"",argv[1],argv[2],argv[3],(unsigned long long)(uintptr_t)permit,(unsigned long long)(uintptr_t)cancel,argv[4],argv[5])<0)return 1;
 BOOL made=CreateProcessW(argv[1],command,NULL,NULL,TRUE,CREATE_NO_WINDOW|CREATE_SUSPENDED|EXTENDED_STARTUPINFO_PRESENT,NULL,NULL,&si.StartupInfo,&pi);
 DeleteProcThreadAttributeList(si.lpAttributeList);HeapFree(GetProcessHeap(),0,si.lpAttributeList);
 if(!made)return 1;
 BOOL started=AssignProcessToJobObject(owned,pi.hProcess) && ResumeThread(pi.hThread)!=(DWORD)-1;
 CloseHandle(pi.hThread);
 DWORD exit_code=1;BOOL finished=started && WaitForSingleObject(pi.hProcess,30000)==WAIT_OBJECT_0 && GetExitCodeProcess(pi.hProcess,&exit_code);
 if(!finished){TerminateProcess(pi.hProcess,127);WaitForSingleObject(pi.hProcess,4000);}
 BOOL consumed=WaitForSingleObject(permit,0)==WAIT_TIMEOUT;
 CloseHandle(pi.hProcess);CloseHandle(permit);CloseHandle(cancel);CloseHandle(owned);
 printf("{\"child_exit\":%lu,\"permit_consumed\":%s,\"explicit_handle_list\":true,\"owned_child_job\":true}\n",(unsigned long)exit_code,consumed?"true":"false");
 return finished && exit_code==4 && consumed?0:1;
}
