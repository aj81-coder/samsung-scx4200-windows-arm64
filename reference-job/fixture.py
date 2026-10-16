"""Create deterministic raster and independently verify SpliX 0x0D QPDL output.
SPDX-License-Identifier: GPL-2.0-only
Requires Pillow. No printer access.
"""
from pathlib import Path
import hashlib, json, struct, sys
from PIL import Image, ImageDraw, ImageFont, ImageOps, __version__ as pillow_version

ROOT = Path(__file__).resolve().parent
W,H = 2480,3509
MX,MY,BH = 48,63,64

def raster():
    im = Image.new('1',(W,H),1)
    d = ImageDraw.Draw(im)
    def text(x,y,s,size=48):
        d.text((x,y),s,font=ImageFont.load_default(size=size),fill=0)
    d.rectangle((150,150,2320,3330),outline=0,width=4)
    text(220,240,'SAMSUNG SCX-4200',76)
    text(220,365,'Native Windows USB test',62)
    text(220,500,'One page / A4 / 300 dpi')
    text(220,610,'Open-source SpliX rendering')
    text(220,810,'Check: text is clear and upright.')
    text(220,910,'Check: all four border edges show.')
    text(220,1010,'Check: exactly one sheet prints.')
    text(220,1240,'0123456789  ABCDEFGHIJKLM')
    text(220,1340,'abcdefghijklm  NOPQRSTUVWXYZ')
    # 300 pixels = 25.4 mm at 300dpi. Sparse geometric checks.
    d.rectangle((220,1570,520,1870),outline=0,width=3)
    d.ellipse((680,1570,980,1870),outline=0,width=3)
    d.line((1140,1570,1440,1870),fill=0,width=3)
    d.line((1140,1870,1440,1570),fill=0,width=3)
    text(220,2000,'Square: approximately 25.4 mm')
    text(220,2250,'This tests USB transport and encoding.')
    text(220,2350,'It is not yet a Windows print queue.')
    text(220,3140,'END OF SINGLE TEST PAGE',50)
    # PNG is full source page; one bits in raw denote black, MSB first.
    im.save(ROOT/'test-page-preview.png',dpi=(300,300))
    (ROOT/'page.raw').write_bytes(ImageOps.invert(im.convert('L')).convert('1').tobytes())

def verify():
    job=(ROOT/'test-page.qpdl').read_bytes()
    marker=b'@PJL ENTER LANGUAGE = QPDL\n'
    assert job.count(marker)==1
    start=job.index(marker)+len(marker)
    assert job.startswith(b'\x1b%-12345X@PJL SET ')
    assert b'DEFAULT' not in job[:start]
    expected=bytes([0,3,0,1,2])+struct.pack('>HH',W,H)+bytes([1,0,1,0,2,1,1,3])
    assert len(expected)==17 and job[start:start+17]==expected
    p=start+17
    decoded=Image.new('1',(W,H),0)
    d=ImageDraw.Draw(decoded)
    previous=-1; bands=0; packets={2:0,4:0,6:0}
    while job[p]==0x0c:
        sig,n,width,height,algo,length=struct.unpack('>BBHHBI',job[p:p+11]);p+=11
        assert previous<n<54 and width==W and height==BH and algo==13
        previous=n;bands+=1
        assert length>=8 and p+length<=len(job)
        data=job[p:p+length-4]
        assert len(data)%4==0
        assert sum(data)==int.from_bytes(job[p+length-4:p+length],'big')
        p+=length
        q=0;x=y=0
        while q<len(data):
            a=data[q]
            if a<0x80:
                assert q+2<=len(data)
                dy=a>>6;run=a&63
                dx=int.from_bytes(data[q+1:q+2],'big',signed=True)
                q+=2;packets[2]+=1
                if run==0:
                    assert dx==dy==0 and not any(data[q:]), 'only trailing padding may be empty'
                    break
                x+=dx;y+=dy
            elif a<0xc0:
                assert q+4<=len(data)
                dx=((a&63)<<8)|data[q+1]
                if dx&8192:dx-=16384
                assert data[q+2]&0xc0==0x80
                dy=(data[q+2]>>4)&3
                run=((data[q+2]&15)<<8)|data[q+3]
                x+=dx;y+=dy;q+=4;packets[4]+=1
            else:
                assert a==0xc0 and q+6<=len(data) and data[q+4]&0xc0==0xc0
                delta=int.from_bytes(data[q+1:q+4],'big')
                y,x=divmod(y*2464+x+delta,2464)
                run=((data[q+4]&63)<<8)|data[q+5]
                q+=6;packets[6]+=1
            assert 0<run and 0<=x<x+run<=2464 and 0<=y<BH
            sy=MY+n*BH+y;sx=MX+x
            assert sy<H and sx+run<=W
            d.line((sx,sy,sx+run-1,sy),fill=1)
    assert job[p:]==b'\x01\x00\x01\x09\x1b%-12345X', 'exactly one page/copy and footer required'
    original=(ROOT/'page.raw').read_bytes()
    assert decoded.tobytes()==original, 'decoded pixels differ from source raster'
    report={'result':'PASS','bytes':len(job),'sha256':hashlib.sha256(job).hexdigest(),
        'pages':1,'copies':1,'paper':'A4','dpi':300,'raster_width':W,'raster_height':H,
        'bands':bands,'band_height':BH,'compression':'0x0D','packet_counts':packets,
        'checks':['exact page header','strict one-page footer','ordered unique bands',
                  'every band checksum','bounds-checked independent decoding',
                  'every decoded pixel equals source raster','no PJL DEFAULT commands'],
        'pillow_version':pillow_version,
        'physical_printer_test':'NOT YET PERFORMED'}
    (ROOT/'validation.json').write_text(json.dumps(report,indent=2)+'\n',encoding='utf-8')
    print(json.dumps(report,indent=2))

if __name__=='__main__':
    if sys.argv[1:] == ['raster']:raster()
    elif sys.argv[1:] == ['verify']:verify()
    else:raise SystemExit('Usage: fixture.py raster|verify')
