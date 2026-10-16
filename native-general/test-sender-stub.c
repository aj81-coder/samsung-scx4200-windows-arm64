// SPDX-License-Identifier: Apache-2.0
/* Test-only child: simulates printer progress and never enumerates USB.
 * Production bridge cannot choose this executable. */
#include <windows.h>
#include <bcrypt.h>
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include "../native-render-print/job_validator.h"
static char progress_hash[65];
static const wchar_t *arg(int n,wchar_t **v,const wchar_t *key){for(int i=1;i+1<n;i++)if(!wcscmp(v[i],key))return v[i+1];return NULL;}
static int progress(const wchar_t *path,const char *stage,unsigned pages,size_t ack,unsigned done){
 wchar_t tmp[32768];if(swprintf(tmp,32768,L"%ls.tmp",path)<0)return 0;
 FILE *f=_wfopen(tmp,L"wb");if(!f)return 0;
 int ok=fprintf(f,"{\"job_sha256\":\"%s\",\"stage\":\"%s\",\"acknowledged_bytes\":%zu,\"pages_data_completed\":%u,\"document_pages\":%u,\"status_byte\":%u,\"elapsed_ms\":200,\"paper_wait_ms\":100,\"status_polls\":2}\n",progress_hash,stage,ack,done,pages,!strcmp(stage,"WAITING_PAPER")?8:24)>0;
 ok=fclose(f)==0 && ok;return ok && MoveFileExW(tmp,path,MOVEFILE_REPLACE_EXISTING|MOVEFILE_WRITE_THROUGH);
}
int wmain(int n,wchar_t **v){
 const wchar_t *job=arg(n,v,L"--jobbundle"),*sha=arg(n,v,L"--sha256");if(!job||!sha)return 64;
 FILE *f=_wfopen(job,L"rb");if(!f)return 65;
 if(_fseeki64(f,0,SEEK_END)){fclose(f);return 66;}
 long long length=_ftelli64(f);rewind(f);if(length<12){fclose(f);return 66;}
 unsigned char *data=malloc(4u*1024u*1024u);if(!data){fclose(f);return 66;}
 BCRYPT_ALG_HANDLE alg=NULL;BCRYPT_HASH_HANDLE hash=NULL;unsigned char digest[32];
 if(BCryptOpenAlgorithmProvider(&alg,BCRYPT_SHA256_ALGORITHM,NULL,0)<0||BCryptCreateHash(alg,&hash,NULL,0,NULL,0,0)<0)return 68;
 long long remain=length;
 while(remain){size_t want=remain>4*1024*1024?4*1024*1024:(size_t)remain;
 if(fread(data,1,want,f)!=want||BCryptHashData(hash,data,(ULONG)want,0)<0)return 68;remain-=want;}
 if(BCryptFinishHash(hash,digest,32,0)<0)return 68;BCryptDestroyHash(hash);BCryptCloseAlgorithmProvider(alg,0);
 char hex[65];for(unsigned i=0;i<32;i++)sprintf(hex+i*2,"%02x",digest[i]);
 if(wcslen(sha)!=64)return 69;for(unsigned i=0;i<64;i++)if(sha[i]!=(wchar_t)hex[i])return 69;strcpy(progress_hash,hex);
 rewind(f);unsigned char head[36];if(fread(head,1,12,f)!=12||memcmp(head,"SCXJOB06",8))return 67;
 unsigned pages=(unsigned)be32(head+8);size_t bytes=0;long long pos=12;
 if(!pages)return 67;
 for(uint64_t i=0;i<pages;i++){
 if(length-pos<36||fread(head,1,36,f)!=36)return 67;pos+=36;DWORD count=(DWORD)be32(head);
 if(!count||count>4u*1024u*1024u||count>(uint64_t)(length-pos)||fread(data,1,count,f)!=count||!validate_job(data,count))return 67;
 if(BCryptOpenAlgorithmProvider(&alg,BCRYPT_SHA256_ALGORITHM,NULL,0)<0||BCryptHash(alg,NULL,0,data,count,digest,32)<0)return 68;BCryptCloseAlgorithmProvider(alg,0);
 if(memcmp(digest,head+4,32))return 67;bytes+=count;pos+=count;
 }
 if(pos!=length)return 67;fclose(f);free(data);
 for(int i=1;i<n;i++)if(!wcscmp(v[i],L"--validate-only"))return 0;
 const wchar_t *permitarg=arg(n,v,L"--permit-handle"),*cancelarg=arg(n,v,L"--cancel-handle"),*report=arg(n,v,L"--report"),*prog=arg(n,v,L"--progress");
 if(!permitarg||!cancelarg||!report||!prog)return 70;
 HANDLE permit=(HANDLE)(uintptr_t)_wcstoui64(permitarg,NULL,10),cancel=(HANDLE)(uintptr_t)_wcstoui64(cancelarg,NULL,10);DWORD flags;
 if(!GetHandleInformation(permit,&flags)||!(flags&HANDLE_FLAG_INHERIT)||!GetHandleInformation(cancel,&flags)||!(flags&HANDLE_FLAG_INHERIT)||WaitForSingleObject(permit,0)!=WAIT_OBJECT_0||!ResetEvent(permit))return 71;
 FILE *call=fopen("stub-calls.txt","ab");if(!call)return 72;fputs("call\n",call);fclose(call);
 char mode[100]="wait";f=fopen("sender-test-mode.txt","rb");if(f){fgets(mode,sizeof(mode),f);fclose(f);}
 if(!progress(prog,"WAITING_PAPER",pages,0,0))return 73;
 FILE *marker=fopen("stub-waiting.txt","wb");if(!marker)return 73;fputs("two valid inherited events; permit consumed; no USB\n",marker);fclose(marker);
 ULONGLONG limit=GetTickCount64()+30000;int cancelled=0;
 while(GetFileAttributesW(L"stub-release.txt")==INVALID_FILE_ATTRIBUTES){if(WaitForSingleObject(cancel,20)==WAIT_OBJECT_0){cancelled=1;break;}if(GetTickCount64()>limit)return 74;}
 int failed=cancelled||!strncmp(mode,"missing",7)||!strncmp(mode,"uncertain",9);size_t ack=!strncmp(mode,"uncertain",9)?bytes/2:failed?0:bytes;
 if(!failed){if(!progress(prog,"SENDING",pages,bytes/2,0))return 73;Sleep(300);}
 f=_wfopen(report,L"wb");if(!f)return 75;
 fprintf(f,"{\"result\":\"%s\",\"job_sha256\":\"%s\",\"job_bytes\":%zu,\"bundle_bytes\":%lld,\"document_pages\":%u,\"job_hash_verified\":true,\"bridge_permit_consumed\":true,\"check_only\":false,\"exclusive_read_write_open\":%s,\"transfer\":{\"attempted\":%s,\"acknowledged_bytes\":%zu,\"pages_data_completed\":%u,\"win32_error\":%u,\"delivery_uncertain\":%s,\"timed_out\":false,\"cancellation_pending\":false},\"printer_wait\":{\"status_polls\":2,\"paper_wait_ms\":100,\"write_requests_replayed\":0}}\n",cancelled?"CANCELLED_NO_DATA_SENT":failed?"TEST_FAILURE":"USB_WRITE_COMPLETED_PHYSICAL_OUTPUT_UNCONFIRMED",hex,bytes,length,pages,failed?"false":"true",ack?"true":"false",ack,failed?0:pages,failed?5:0,ack&&failed?"true":"false");
 if(fclose(f))return 75;if(!progress(prog,failed?"FAILED":"COMPLETE",pages,ack,failed?0:pages))return 73;
 return failed?4:0;
}
