// Encode a test image through NullMoth's production nve264 path with the luma pre-permuted for a
// candidate hardware layout, decode it with VideoToolbox and report luma/chroma PSNR.
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <VideoToolbox/VideoToolbox.h>
typedef void*(*OpenFn)(int,int);
typedef int(*EncFn)(void*,const uint8_t*,size_t,const uint8_t*,size_t,int,int,int,int,uint8_t**,size_t*,int*,void**);
typedef int(*HdrFn)(int,int,int,int,uint8_t*,size_t);
typedef void(*CloseFn)(void*);
enum{W=1280,H=720};
static uint8_t srcY[W*H],srcUV[W*H/2],inY[W*H],decY[W*H],decUV[W*H/2];
static int got;
/* offset of pixel (x 0..63, y 0..15) inside a 64x16 (1024-byte) block */
static int L_bw8(int x,int y){return (y&8)*64+((x>>3)&7)*64+(y&7)*8+(x&7);}
static int L_std(int x,int y){y&=15;int g=(y>>3)*512;y&=7;return g+(x&0x20)*8+((y&6)<<5)+(x&0x10)*2+((y&1)<<4)+(x&15);}
static int L_t2d(int x,int y){int g=(y>>3)*512;y&=7;return g+(x&0x20)*8+(x&0x10)*4+((y&4)<<5)+((y&3)<<4)+(x&15);}
static int L_bw16(int x,int y){int g=(y>>3)*512;y&=7;return g+(x&0x30)*8+(y&7)*16+(x&15);}
static int L_lin(int x,int y){return y*64+x;}
static void cb(void*r,void*s,OSStatus st,VTDecodeInfoFlags f,CVImageBufferRef ib,CMTime p,CMTime d){
 if(st||!ib){fprintf(stderr,"decode status %d\n",(int)st);return;}
 CVPixelBufferLockBaseAddress(ib,1);
 uint8_t*y=CVPixelBufferGetBaseAddressOfPlane(ib,0);size_t ys=CVPixelBufferGetBytesPerRowOfPlane(ib,0);
 uint8_t*uv=CVPixelBufferGetBaseAddressOfPlane(ib,1);size_t us=CVPixelBufferGetBytesPerRowOfPlane(ib,1);
 for(int j=0;j<H;j++)memcpy(decY+j*W,y+j*ys,W);for(int j=0;j<H/2;j++)memcpy(decUV+j*W,uv+j*us,W);
 CVPixelBufferUnlockBaseAddress(ib,1);got=1;}
static double psnr(uint8_t*a,uint8_t*b,int n){double e=0;for(int i=0;i<n;i++){double d=a[i]-b[i];e+=d*d;}e/=n;return e==0?99:10*log10(255*255/e);}
int main(int argc,char**argv){
 const char*lib=argv[1];const char*name=argv[2];
 int(*G)(int,int)=!strcmp(name,"std")?L_std:!strcmp(name,"t2d")?L_t2d:!strcmp(name,"bw16")?L_bw16:!strcmp(name,"lin")?L_lin:L_bw8;
 for(int j=0;j<H;j++)for(int i=0;i<W;i++){double dx=i-W/2.0,dy=j-H/2.0,r=sqrt(dx*dx+dy*dy);int v;
  if(j<H/3)v=16+(i*219)/W;else if(j<2*H/3)v=(((i/24)+(j/24))&1)?200:40;else v=128+90*sin(r/9.0);
  if(abs(i-j*W/H)<3)v=235;srcY[j*W+i]=v;}
 for(int j=0;j<H/2;j++)for(int i=0;i<W/2;i++){srcUV[j*W+2*i]=(((i/5)+(j/7))&1)?200:60;srcUV[j*W+2*i+1]=(((i/3)+(j/11))&1)?180:70;}
 /* inverse of G inside a block */
 int inv[1024][2];for(int y=0;y<16;y++)for(int x=0;x<64;x++){int o=G(x,y);inv[o][0]=x;inv[o][1]=y;}
 for(int j=0;j<H;j++)for(int i=0;i<W;i++){int bx=i&~63,by=j&~15;int o=L_bw8(i&63,j&15);int sx=bx+inv[o][0],sy=by+inv[o][1];
  if(sy>=H)sy=H-1;inY[j*W+i]=srcY[sy*W+sx];}
 static uint8_t inUV[W*H/2];const char*cn=argc>4?argv[4]:"bw16";
 int(*C)(int,int)=!strcmp(cn,"std")?L_std:!strcmp(cn,"t2d")?L_t2d:!strcmp(cn,"bw8")?L_bw8:L_bw16;
 int cinv[1024][2];for(int y=0;y<16;y++)for(int x=0;x<64;x++){int o=C(x,y);cinv[o][0]=x;cinv[o][1]=y;}
 for(int j=0;j<H/2;j++)for(int i=0;i<W;i++){int bx=i&~63,by=j&~15;int o=L_bw16(i&63,j&15);int sx=bx+cinv[o][0],sy=by+cinv[o][1];
  if(sy>=H/2)sy=H/2-1;inUV[j*W+i]=srcUV[sy*W+sx];}
 void*h=dlopen(lib,RTLD_NOW);if(!h){puts(dlerror());return 1;}
 OpenFn op=dlsym(h,"nve264_open");EncFn en=dlsym(h,"nve264_encode");HdrFn hd=dlsym(h,"nve264_headers");CloseFn cl=dlsym(h,"nve264_close");
 void*ctx=op(W,H);if(!ctx){puts("open failed");return 1;}
 uint8_t hdr[512];int hl=hd(W,H,0,0,hdr,512);
 uint8_t*out=0;size_t ol=0;int key=0;void*aux=0;
 int rc=en(ctx,inY,W,inUV,W,atoi(argc>3?argv[3]:"23"),0,60,1,&out,&ol,&key,&aux);
 printf("%-5s headers %d encode rc %d bytes %zu key %d\n",name,hl,rc,ol,key);
 if(rc||!out){cl(ctx);return 1;}
 /* split annexB: headers + frame */
 size_t tl=hl+ol;uint8_t*all=malloc(tl);memcpy(all,hdr,hl);memcpy(all+hl,out,ol);
 char fn[256];snprintf(fn,256,"%s.h264",name);FILE*f=fopen(fn,"wb");fwrite(all,1,tl,f);fclose(f);
 const uint8_t*ps[2];size_t pl[2];int np=0;uint8_t*nal[64];size_t nl[64];int nn=0;
 for(size_t i=0;i+3<tl;){ if(all[i]==0&&all[i+1]==0&&all[i+2]==1){size_t s=i+3,e=s;while(e+3<=tl&&!(all[e]==0&&all[e+1]==0&&(all[e+2]==1||(all[e+2]==0&&e+3<tl&&all[e+3]==1))))e++;if(e+3>tl)e=tl;
   int t=all[s]&31;if(t==7||t==8){if(np<2){ps[np]=all+s;pl[np++]=e-s;}}else{nal[nn]=all+s;nl[nn++]=e-s;}i=e;}else i++;}
 CMFormatDescriptionRef fd;OSStatus st=CMVideoFormatDescriptionCreateFromH264ParameterSets(0,np,ps,pl,4,&fd);if(st){printf("fd %d np %d\n",(int)st,np);return 1;}
 size_t sz=0;for(int k=0;k<nn;k++)sz+=4+nl[k];uint8_t*av=malloc(sz),*p=av;for(int k=0;k<nn;k++){uint32_t L=nl[k];*p++=L>>24;*p++=L>>16;*p++=L>>8;*p++=L;memcpy(p,nal[k],L);p+=L;}
 CMBlockBufferRef bb;CMBlockBufferCreateWithMemoryBlock(0,av,sz,kCFAllocatorNull,0,0,sz,0,&bb);
 CMSampleBufferRef sb;CMSampleBufferCreateReady(0,bb,fd,1,0,0,1,&sz,&sb);
 VTDecompressionOutputCallbackRecord r={cb,0};VTDecompressionSessionRef ds;
 int pf=kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;CFNumberRef n=CFNumberCreate(0,kCFNumberIntType,&pf);
 const void*k[]={kCVPixelBufferPixelFormatTypeKey};const void*v[]={n};CFDictionaryRef at=CFDictionaryCreate(0,k,v,1,&kCFTypeDictionaryKeyCallBacks,&kCFTypeDictionaryValueCallBacks);
 st=VTDecompressionSessionCreate(0,fd,0,at,&r,&ds);if(st){printf("ds %d\n",(int)st);return 1;}
 VTDecompressionSessionDecodeFrame(ds,sb,0,0,0);VTDecompressionSessionWaitForAsynchronousFrames(ds);
 if(got){printf("%-5s luma PSNR %.2f dB  chroma PSNR %.2f dB\n",name,psnr(srcY,decY,W*H),psnr(srcUV,decUV,W*H/2));
  snprintf(fn,256,"%s.pgm",name);f=fopen(fn,"wb");fprintf(f,"P5 %d %d 255\n",W,H*2);fwrite(srcY,1,W*H,f);fwrite(decY,1,W*H,f);fclose(f);}
 cl(ctx);return 0;}
