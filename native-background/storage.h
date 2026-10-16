// SPDX-License-Identifier: Apache-2.0
/* Only completed jobs in this process enter this ring. Unknown/failed work is
 * never erased to make room. All paths are generated beneath our data cwd. */
static char successful_jobs[10][1024],previous_success[1024];
static unsigned successful_slot;
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
 for(unsigned p=1;p<=10;p++){
  char leaf[64];
  const char *suffixes[]={"pgm","qpdl","json","qpdl.json"};
  for(unsigned s=0;s<(metadata?4u:2u);s++){
   snprintf(leaf,sizeof(leaf),"page-%02u.%s",p,suffixes[s]);if(!remove_generated(directory,leaf))return false;
  }
 }
 if(!remove_generated(directory,"document.scxjob"))return false;
 if(metadata){
  const char *names[]={"bridge-result.json","sender-report.json","sender-progress.json","SEND_STARTED.json","mock-transport.json"};
  for(unsigned i=0;i<sizeof(names)/sizeof(names[0]);i++)if(!remove_generated(directory,names[i]))return false;
  if(!RemoveDirectoryA(directory))return false; /* Unknown files are preserved. */
 }
 return true;
}
static bool data_size(const char *directory,unsigned depth,unsigned *entries,uint64_t *bytes) {
 if(depth>8)return false;
 char pattern[1200];if(snprintf(pattern,sizeof(pattern),"%s/*",directory)>=(int)sizeof(pattern))return false;
 WIN32_FIND_DATAA f;HANDLE h=FindFirstFileA(pattern,&f);if(h==INVALID_HANDLE_VALUE)return false;
 bool ok=true;
 do{
  if(!strcmp(f.cFileName,".") || !strcmp(f.cFileName,".."))continue;
  if(++*entries>4096 || (f.dwFileAttributes&FILE_ATTRIBUTE_REPARSE_POINT)){ok=false;break;}
  if(f.dwFileAttributes&FILE_ATTRIBUTE_DIRECTORY){
   char child[1200];int n=snprintf(child,sizeof(child),"%s/%s",directory,f.cFileName);
   if(n<0 || n>=(int)sizeof(child) || !data_size(child,depth+1,entries,bytes)){ok=false;break;}
  }else{
   *bytes+=((uint64_t)f.nFileSizeHigh<<32)|f.nFileSizeLow;
   if(*bytes>512ull*1024*1024){ok=false;break;}
  }
 }while(FindNextFileA(h,&f));
 if(ok && GetLastError()!=ERROR_NO_MORE_FILES)ok=false;
 FindClose(h);return ok;
}
static bool storage_admission(void) {
 if(previous_success[0]){if(!prune_success(previous_success,false))return false;previous_success[0]=0;}
 if(successful_jobs[successful_slot][0]){
  if(!prune_success(successful_jobs[successful_slot],true))return false;
  successful_jobs[successful_slot][0]=0;
 }
 unsigned entries=0;uint64_t bytes=0;ULARGE_INTEGER free_bytes;
 return data_size(".",0,&entries,&bytes) && GetDiskFreeSpaceExW(L".",&free_bytes,NULL,NULL) && free_bytes.QuadPart>=512ull*1024*1024;
}
static void remember_success(void) {
 strcpy(previous_success,bridge.directory);
 strcpy(successful_jobs[successful_slot],bridge.directory);
 successful_slot=(successful_slot+1)%10;
}
