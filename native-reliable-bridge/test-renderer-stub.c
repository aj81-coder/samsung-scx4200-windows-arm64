// SPDX-License-Identifier: Apache-2.0
/* Second-page failure/cancellation fixture. No USB or printer API. */
#include <windows.h>
#include <stdio.h>
#include <string.h>
#include <wchar.h>
int wmain(int argc,wchar_t **argv) {
  char mode[32]={0}; FILE *f=fopen("test-mode.txt","rb");
  if(f){fgets(mode,sizeof(mode),f);fclose(f);}
  if(argc!=3)return 64;
  if(wcsstr(argv[1],L"page-02")) {
    f=fopen("second-renderer-started.txt","wb");if(f){fputs("started",f);fclose(f);}
    if(!strncmp(mode,"delay",5))Sleep(5000);
    if(!strncmp(mode,"invalid",7)){f=_wfopen(argv[2],L"wb");if(f){fputs("invalid QPDL",f);fclose(f);}return 0;}
    return 7;
  }
  wchar_t command[65536];STARTUPINFOW si={0};PROCESS_INFORMATION pi={0};DWORD code=1;
  si.cb=sizeof(si);
  if(swprintf(command,65536,L"\"real-renderer.exe\" \"%ls\" \"%ls\"",argv[1],argv[2])<0)return 65;
  if(!CreateProcessW(L"real-renderer.exe",command,NULL,NULL,FALSE,CREATE_NO_WINDOW,NULL,NULL,&si,&pi))return 66;
  CloseHandle(pi.hThread);WaitForSingleObject(pi.hProcess,INFINITE);GetExitCodeProcess(pi.hProcess,&code);CloseHandle(pi.hProcess);
  return (int)code;
}
