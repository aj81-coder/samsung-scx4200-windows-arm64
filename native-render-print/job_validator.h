// SPDX-License-Identifier: Apache-2.0
/* Independent, deliberately narrow SCX-4200 one-page QPDL validator. */
#ifndef SCX_JOB_VALIDATOR_H
#define SCX_JOB_VALIDATOR_H
static const unsigned char job_prefix[] =
    "\033%-12345X@PJL SET USERNAME=\"SCX4200 test\"\n"
    "@PJL SET JOBNAME=\"SCX4200 native USB test\"\n"
    "@PJL SET JAMRECOVERY=OFF\n@PJL SET DUPLEX=OFF\n"
    "@PJL SET PAPERTYPE=NORMAL\n@PJL SET ALTITUDE=LOW\n"
    "@PJL SET DENSITY=3\n@PJL SET RET=NORMAL\n"
    "@PJL ENTER LANGUAGE = QPDL\n";
static const unsigned char page_header[]={0,3,0,1,2,9,176,13,181,1,0,1,0,2,1,1,3};
static const unsigned char job_footer[]={1,0,1,9,27,37,45,49,50,51,52,53,88};
static unsigned be16(const unsigned char *p) {return ((unsigned)p[0]<<8)|p[1];}
static unsigned long be32(const unsigned char *p) {return ((unsigned long)p[0]<<24)|((unsigned long)p[1]<<16)|((unsigned long)p[2]<<8)|p[3];}
static BOOL validate_0e(const unsigned char *data,size_t count,unsigned band) {
    size_t q=0;
    for(unsigned row=0;row<64;row++) {
        unsigned column=0;
        while(column<308) {
            if(q>=count) return FALSE;
            unsigned control=data[q++],run;BOOL literal=FALSE;
            if(control>=0x40 && control<=0x7f)run=129-control;
            else if(control==0xfe || control==0xff) {
                if(q>=count)return FALSE;
                run=65537-((control<<8)|data[q++]);
                if(run<66)return FALSE;
            } else if(control==0x80 || control==0x81) {
                if(q>=count)return FALSE;
                run=(((control&127)<<8)|data[q++])+1;literal=TRUE;
            } else return FALSE;
            if(run>308-column || (literal ? run : 1)>count-q)return FALSE;
            for(unsigned i=0;i<run;i++) {
                unsigned value=data[q+(literal?i:0)];
                /* 0x0e white=0xff; ink must fit the same source-page bounds
                 * imposed on the independently decoded 0x0d packets. */
                if((column+i>=304 || 63+band*64+row>=3509) && value!=255)return FALSE;
            }
            q+=literal?run:1;column+=run;
        }
    }
    if(count-q>3)return FALSE;
    while(q<count)if(data[q++])return FALSE;
    return TRUE;
}
static BOOL validate_job(const unsigned char *data,size_t size) {
    size_t p=sizeof(job_prefix)-1;
    if(size>4*1024*1024 || size<p+sizeof(page_header)+sizeof(job_footer) ||
       memcmp(data,job_prefix,p) || memcmp(data+p,page_header,sizeof(page_header))) return FALSE;
    p+=sizeof(page_header);
    int previous=-1;
    while(p<size && data[p]==12) {
        if(size-p<11) return FALSE;
        unsigned band=data[p+1];
        if((int)band<=previous || band>=54 || be16(data+p+2)!=2480 || be16(data+p+4)!=64 || (data[p+6]!=13 && data[p+6]!=14)) return FALSE;
        unsigned algorithm=data[p+6];
        previous=(int)band;
        size_t length=be32(data+p+7);p+=11;
        if(length<8 || length>size-p || (length-4)%4) return FALSE;
        size_t count=length-4,q=0; unsigned long checksum=0;
        for(size_t i=0;i<count;i++) checksum+=data[p+i];
        if(checksum!=be32(data+p+count)) return FALSE;
        if(algorithm==14) {
            if(!validate_0e(data+p,count,band))return FALSE;
            p+=length;continue;
        }
        int x=0,y=0;
        while(q<count) {
            unsigned a=data[p+q],run=0;
            if(a<128) {
                if(count-q<2) return FALSE;
                int dx=(signed char)data[p+q+1];unsigned dy=a>>6;
                run=a&63;q+=2;
                if(!run) {
                    if(dx || dy) return FALSE;
                    while(q<count) if(data[p+q++]) return FALSE;
                    break;
                }
                x+=dx;y+=(int)dy;
            } else if(a<192) {
                if(count-q<4 || (data[p+q+2]&192)!=128) return FALSE;
                int dx=(int)(((a&63)<<8)|data[p+q+1]);if(dx&8192)dx-=16384;
                y+=(data[p+q+2]>>4)&3;x+=dx;
                run=((data[p+q+2]&15)<<8)|data[p+q+3];q+=4;
            } else {
                if(a!=192 || count-q<6 || (data[p+q+4]&192)!=192) return FALSE;
                unsigned delta=((unsigned)data[p+q+1]<<16)|((unsigned)data[p+q+2]<<8)|data[p+q+3];
                unsigned linear=(unsigned)(y*2464+x)+delta;
                y=(int)(linear/2464);x=(int)(linear%2464);
                run=((data[p+q+4]&63)<<8)|data[p+q+5];q+=6;
            }
            if(!run || x<0 || y<0 || y>=64 || x+(int)run>2464 ||
               48+x+(int)run>2480 || 63+band*64+(unsigned)y>=3509) return FALSE;
        }
        p+=length;
    }
    return size-p==sizeof(job_footer) && !memcmp(data+p,job_footer,sizeof(job_footer));
}
#endif
