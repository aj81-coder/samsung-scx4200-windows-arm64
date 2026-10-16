# SPDX-License-Identifier: Apache-2.0
from pathlib import Path
p=Path(__file__).resolve().parent
s=(p.parent/'native-reliable-bridge/test-sender-stub.c').read_text()
s=s.replace('static char progress_hash[65];','#include "../native-render-print/job_validator.h"\nstatic char progress_hash[65];')
s=s.replace('static unsigned be32(const unsigned char *p){return ((unsigned)p[0]<<24)|((unsigned)p[1]<<16)|((unsigned)p[2]<<8)|p[3];}\n','')
a=s.index(' FILE *f=_wfopen(job,');b=s.index(' for(int i=1;i<n;i++)if',a)
s=s[:a]+r''' FILE *f=_wfopen(job,L"rb");if(!f)return 65;
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
''' + s[b:]
s=s.replace('"bundle_bytes\\\":%ld','"bundle_bytes\\\":%lld')
(p/'test-sender-stub.c').write_text(s)
