/* ===========================================================================
 * touch_shim.c  —  LD_PRELOAD shim for vendor.xiaomi.hw.touchfeature-service
 * ===========================================================================
 *
 * Role in the chagall touch bring-up
 * ----------------------------------
 * On the Xiaomi 17T (chagall) the Novatek NT38771 runs in THP mode: the kernel
 * driver ships raw capacitance frames and a USERSPACE service computes the
 * finger coordinates (TensorFlow Lite via libtouchreport_alg) and reports them.
 * A stock standalone TWRP has no such service, so there is no touch. This shim
 * lets us run the STOCK service inside recovery.
 *
 * The CORE coordinate path does NOT use binder — the service reads raw frames
 * from /dev/xiaomi-touch and reports via /dev/input (confirmed by DT_NEEDED +
 * strings analysis). Its binder dependencies are AUXILIARY features:
 *   - android.frameworks.sensorservice / android.hardware.sensors  (prox/palm)
 *   - vendor.xiaomi.hardware.framecapturemanager                   (frame dump)
 *   - vendor.xiaomi.hardware.fingerprintextension                  (FOD)
 *   - vendor.mediatek.hardware.mtkpower                            (touch boost)
 * None of these exist in recovery. Like ks2_log.c stubbed apexd/strongbox, we
 * return NULL immediately for them so the service's worker threads never block
 * forever waiting on a service manager entry that will never appear.
 *
 * Hooks:
 *   - AServiceManager_waitForService / getService / checkService
 *       -> NULL immediately for the auxiliary HALs (is_aux); trace + forward
 *          everything else (incl. the service's own ITouchFeature registration).
 *   - Stability::requiresVintfDeclaration -> false, Stability::check -> 0
 *       so the service can register ITouchFeature without a VINTF blessing.
 *   - VintfObject::fetchDeviceHalManifest ELOOP(-40) -> 0  (defensive)
 *   - abort() -> kill the calling thread only (SYS_exit 93), not the process,
 *       so a crashing auxiliary thread (sensors/FOD) does not take down the
 *       coordinate loop. (Same breakthrough as twrp_fix.c.)
 *   - open/openat -> trace the hardware nodes the core loop touches
 *       (/dev/xiaomi-touch, /dev/input, /dev/uinput, /sys/class/touch) so we can
 *       see in the log whether the service reached the IC and started injecting.
 *
 * Build:  aarch64-linux-gnu-gcc -shared -fPIC -nostdlib -O0 -std=c11 \
 *             -o touch_shim.so touch_shim.c
 * Only hook C++ symbols with TRIVIAL signatures (see the ABI warning in the
 * degas RESEARCH.md — hidden return pointers crash). Everything below is either
 * a C NDK symbol or a trivial-return C++ method.
 * ===========================================================================
 */
#define bool int
#include <stddef.h>

#define RTLD_NEXT_T ((void*)-1L)
extern void* dlsym(void*,const char*) __attribute__((weak));

/* Write a NUL-terminated string straight to stderr via SYS_write (x8=64). */
static void wr(const char* s){
    if(!s||!*s)return;
    const char* e=s;while(*e)e++;
    __asm__ volatile(
        "mov x8,#64\nmov x0,#2\nmov x1,%0\nsub x2,%1,%0\nsvc #0\n"
        ::"r"(s),"r"(e):"x0","x1","x2","x8","memory");}

static int startswith(const char* s,const char* p){
    if(!s||!p)return 0;
    int i=0;while(p[i]&&s[i]&&p[i]==s[i])i++;return !p[i];}

static int contains(const char* s,const char* p){
    if(!s||!p)return 0;
    for(int i=0;s[i];i++){int k=0;while(p[k]&&s[i+k]==p[k])k++;if(!p[k])return 1;}
    return 0;}

__attribute__((constructor)) static void init(void){wr("=== touch_shim loaded ===\n");}

/* Mirror the service's liblog output into our stderr log. */
int __android_log_buf_write(int b,int p,const char* t,const char* m){
    wr("[TF LOG] ");if(t){wr(t);wr(":");}if(m)wr(m);wr("\n");return 1;}
int __android_log_write(int p,const char* t,const char* m){
    wr("[TF LOG] ");if(t){wr(t);wr(":");}if(m)wr(m);wr("\n");return 1;}
int __android_log_print(int p,const char* t,const char* fmt,...){
    wr("[TF LOG] ");if(t){wr(t);wr(":");}if(fmt)wr(fmt);wr("\n");return 1;}

/* abort -> kill calling thread only (SYS_exit 93), not the whole process. */
__attribute__((noreturn)) void abort(void){
    wr("[TF] ABORT - killing thread only\n");
    register long x8 __asm__("x8")=93,x0 __asm__("x0")=1;
    __asm__ volatile("svc #0":"+r"(x0):"r"(x8):"memory");
    while(1){}}

/* android::internal::Stability::requiresVintfDeclaration(sp<IBinder>) -> false
 * android::internal::Stability::check(short, Level)                  -> 0    */
bool _ZN7android8internal9Stability24requiresVintfDeclarationERKNS_2spINS_7IBinderEEE(void* sp){
    (void)sp;return 0;}
int _ZN7android8internal9Stability5checkEsNS1_5LevelE(short s,int l){
    (void)s;(void)l;return 0;}

/* VintfObject::fetchDeviceHalManifest -> force OK on ELOOP (defensive; only
 * matters if libvintf gets pulled in). */
int _ZN7android5vintf11VintfObject22fetchDeviceHalManifestEPNS0_11HalManifestEPNSt3__112basic_stringIcNS4_11char_traitsIcEENS4_9allocatorIcEEEE(void*self,void*man,void*err){
    typedef int(*fn)(void*,void*,void*);static fn real=0;
    if(!real&&dlsym)real=(fn)dlsym(RTLD_NEXT_T,
        "_ZN7android5vintf11VintfObject22fetchDeviceHalManifestEPNS0_11HalManifestEPNSt3__112basic_stringIcNS4_11char_traitsIcEENS4_9allocatorIcEEEE");
    int r=real?real(self,man,err):-99;
    if(r==-40){wr("[TF] fetchDeviceHalManifest ELOOP->OK\n");r=0;}
    return r;}

/* ── Auxiliary HALs that never exist in recovery → NULL immediately ──
   Returning NULL keeps the service's worker threads from blocking forever on a
   waitForService that can never resolve. The core coordinate path
   (/dev/xiaomi-touch -> TFLite -> /dev/input) does not need any of these.    */
static int is_aux(const char* n){
    if(!n)return 0;
    if(contains(n,"sensorservice"))                          return 1;
    if(contains(n,"hardware.sensors"))                       return 1;
    if(contains(n,"framecapturemanager"))                    return 1;
    if(contains(n,"fingerprintextension"))                   return 1;
    if(contains(n,"mtkpower"))                               return 1;
    return 0;}

void* AServiceManager_waitForService(const char* n){
    wr("[TF WFS] ");if(n)wr(n);wr("\n");
    if(is_aux(n)){wr("[TF WFS] -> NULL (aux, skipped)\n");return 0;}
    typedef void*(*fn)(const char*);static fn real=0;
    if(!real&&dlsym)real=(fn)dlsym(RTLD_NEXT_T,"AServiceManager_waitForService");
    void* r=real?real(n):0;
    wr(r?"[TF WFS] -> FOUND\n":"[TF WFS] -> NULL\n");return r;}

void* AServiceManager_getService(const char* n){
    wr("[TF GET] ");if(n)wr(n);wr("\n");
    if(is_aux(n)){wr("[TF GET] -> NULL (aux, skipped)\n");return 0;}
    typedef void*(*fn)(const char*);static fn real=0;
    if(!real&&dlsym)real=(fn)dlsym(RTLD_NEXT_T,"AServiceManager_getService");
    void* r=real?real(n):0;
    wr(r?"[TF GET] -> FOUND\n":"[TF GET] -> NULL\n");return r;}

void* AServiceManager_checkService(const char* n){
    wr("[TF CHK] ");if(n)wr(n);wr("\n");
    if(is_aux(n)){wr("[TF CHK] -> NULL (aux, skipped)\n");return 0;}
    typedef void*(*fn)(const char*);static fn real=0;
    if(!real&&dlsym)real=(fn)dlsym(RTLD_NEXT_T,"AServiceManager_checkService");
    void* r=real?real(n):0;
    wr(r?"[TF CHK] -> FOUND\n":"[TF CHK] -> NULL\n");return r;}

/* Trace the service registering its own ITouchFeature interface. */
int AServiceManager_addService(void* binder,const char* name){
    wr("[TF ADD] ");if(name)wr(name);wr("\n");
    typedef int(*fn)(void*,const char*);static fn real=0;
    if(!real&&dlsym)real=(fn)dlsym(RTLD_NEXT_T,"AServiceManager_addService");
    int r=real?real(binder,name):-1;
    wr(r==0?"[TF ADD] -> OK\n":"[TF ADD] -> FAIL\n");return r;}

/* ── open/openat: trace the hardware nodes the core loop touches ── */
static int interesting(const char* p){
    if(!p)return 0;
    return startswith(p,"/dev/xiaomi-touch")||startswith(p,"/dev/xiaomi-thp")||
           startswith(p,"/dev/input")||startswith(p,"/dev/uinput")||
           startswith(p,"/sys/class/touch")||startswith(p,"/proc/tp_");}

int open(const char* p,int f,...){
    typedef int(*fn)(const char*,int,...);
    static fn r=0;if(!r&&dlsym)r=(fn)dlsym(RTLD_NEXT_T,"open");
    int fd=-1;
    if(f&0100){void* m;__asm__ volatile("ldr %0,[sp]":"=r"(m));fd=r?r(p,f,m):-1;}
    else fd=r?r(p,f):-1;
    if(interesting(p)){wr("[TF OPEN] ");wr(p);wr(fd<0?" FAIL\n":" OK\n");}
    return fd;}

int openat(int d,const char* p,int f,...){
    typedef int(*fn)(int,const char*,int,...);
    static fn r=0;if(!r&&dlsym)r=(fn)dlsym(RTLD_NEXT_T,"openat");
    int fd=-1;
    if(f&0100){void* m;__asm__ volatile("ldr %0,[sp]":"=r"(m));fd=r?r(d,p,f,m):-1;}
    else fd=r?r(d,p,f):-1;
    if(interesting(p)){wr("[TF OAT] ");wr(p);wr(fd<0?" FAIL\n":" OK\n");}
    return fd;}
