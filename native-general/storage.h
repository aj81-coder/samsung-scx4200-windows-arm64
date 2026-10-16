// SPDX-License-Identifier: Apache-2.0
/* Completed-only allowlisted cleanup; page counts come from our successful
 * jobs, never filenames or an untrusted request's declared page count. */
static char successful_jobs[10][1024],previous_success[1024];
static unsigned successful_pages[10],previous_success_pages,successful_slot;
static bool remove_generated(const char *directory,const char *leaf) {
 char path[1200];int n=snprintf(path,sizeof(path),"%s/%s",directory,leaf);
 if(n<0 || n>=(int)sizeof(path))return false;
 DWORD attr=GetFileAttributesA(path);
 if(attr==INVALID_FILE_ATTRIBUTES)return GetLastError()==ERROR_FILE_NOT_FOUND;
 if(attr&(FILE_ATTRIBUTE_REPARSE_POINT|FILE_ATTRIBUTE_DIRECTORY))return false;
 return DeleteFileA(path)!=0;
}
static bool prune_success(const char *directory,bool metadata) {
 DWORD attr=GetFileAttributesA(directory);
 if(attr==INVALID_FILE_ATTRIBUTES || !(attr&FILE_ATTRIBUTE_DIRECTORY) || (attr&FILE_ATTRIBUTE_REPARSE_POINT))return false;
 unsigned pages=0;
 if(!strcmp(directory,previous_success))pages=previous_success_pages;
 for(unsigned i=0;!pages && i<10;i++)if(!strcmp(directory,successful_jobs[i]))pages=successful_pages[i];
 if(!pages)return false;
 for(uint64_t p=1;p<=(uint64_t)pages;p++){
  char leaf[64];const char *suffixes[]={"pgm","qpdl","json","qpdl.json"};
  for(unsigned s=0;s<4;s++){
   snprintf(leaf,sizeof(leaf),"page-%02u.%s",(unsigned)p,suffixes[s]);if(!remove_generated(directory,leaf))return false;
  }
 }
 if(!remove_generated(directory,"document.scxjob"))return false;
 if(metadata){
  const char *names[]={"bridge-result.json","sender-report.json","sender-progress.json","SEND_STARTED.json","mock-transport.json","pages.index"};
  for(unsigned i=0;i<sizeof(names)/sizeof(names[0]);i++)if(!remove_generated(directory,names[i]))return false;
  if(!RemoveDirectoryA(directory))return false;
 }
 return true;
}
static bool storage_admission(void) {
 if(previous_success[0]){if(!prune_success(previous_success,false))return false;previous_success[0]=0;}
 if(successful_jobs[successful_slot][0]){
  if(!prune_success(successful_jobs[successful_slot],true))return false;
  successful_jobs[successful_slot][0]=0;
 }
 ULARGE_INTEGER free_bytes;
 return GetDiskFreeSpaceExW(L".",&free_bytes,NULL,NULL) && free_bytes.QuadPart>=128ull*1024*1024;
}
static void remember_success(void) {
 strcpy(previous_success,bridge.directory);previous_success_pages=bridge.pages;
 strcpy(successful_jobs[successful_slot],bridge.directory);successful_pages[successful_slot]=bridge.pages;
 successful_slot=(successful_slot+1)%10;
}
