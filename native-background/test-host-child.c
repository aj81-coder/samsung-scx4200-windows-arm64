// SPDX-License-Identifier: Apache-2.0
/* Device-free fixture. This program contains no printer, network or USB code. */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdio.h>
#include <string.h>
static int exists(const char *name){return GetFileAttributesA(name)!=INVALID_FILE_ATTRIBUTES;}
int main(int argc,char **argv) {
 if(argc!=2 || strcmp(argv[1],"--background"))return 64;
 FILE *file=fopen("fixture-launches.txt","a");if(!file)return 1;
 fprintf(file,"%lu\n",GetCurrentProcessId());fclose(file);
 HANDLE lock=CreateFileW(L"SESSION-ACTIVE.lock",GENERIC_WRITE,0,NULL,CREATE_NEW,FILE_ATTRIBUTE_NORMAL,NULL);
 if(lock==INVALID_HANDLE_VALUE)return 2;CloseHandle(lock);
 wchar_t name[128];
 swprintf(name,128,L"Local\\SCX4200.Stop.%lu",GetCurrentProcessId());
 HANDLE stop=CreateEventW(NULL,TRUE,FALSE,name);
 swprintf(name,128,L"Local\\SCX4200.Ready.%lu",GetCurrentProcessId());
 HANDLE ready=CreateEventW(NULL,TRUE,FALSE,name);
 if(!stop || !ready)return 3;
 printf("DEVICE-FREE FIXTURE READY %lu\n",GetCurrentProcessId());fflush(stdout);SetEvent(ready);
 DWORD start=GetTickCount();int exit_code=90;
 while(GetTickCount()-start<90000) {
  if(exists("fixture-fail")){exit_code=23;break;}
  if(exists("fixture-busy"))ResetEvent(ready);else SetEvent(ready);
  if(WaitForSingleObject(stop,25)==WAIT_OBJECT_0){if(exists("fixture-stop-delay"))Sleep(750);if(exists("fixture-stop-long-delay"))Sleep(4000);exit_code=0;break;}
 }
 ResetEvent(ready);CloseHandle(ready);CloseHandle(stop);
 if(exit_code==0)DeleteFileW(L"SESSION-ACTIVE.lock");
 printf("DEVICE-FREE FIXTURE EXIT %d\n",exit_code);fflush(stdout);return exit_code;
}
