/* Compiled management producer/copy; admission, MFP and message transport are models. */
#include <stdint.h>
#include <stddef.h>
static uint32_t unexpected;
uintptr_t diagnostic_model(void) { return 0; }
#include "bindings.h"
unsigned char error_flag __asm__(ERROR_FLAG);
extern uint8_t rxu_cntrl_env[96], sta_info_tab[2576], vif_info_tab[3024], vif_mgmt_env[20];
extern uint32_t rxu_mgt_frame_check(void *, uint8_t);
uint8_t g_bl_ops_funcs[256];
static uint32_t sw[25], mpdu[6], chain[2][13], message[1024];
static uint32_t buffers[3][436], saved_buffers[3][436], saved_chain[2][13];
static uint8_t expected[2400];
struct sample { uint16_t fc; uint8_t kind, security, whole, destination, unbound; };
static const struct sample samples[] = {
    {0x00b0,0,0,0,4,0}, {0x0010,0,0,0,4,0}, {0x0050,0,0,1,2,0},
    {0x0080,0,0,1,2,0}, {0x40c0,0,8,1,4,0}, {0x40a0,2,8,1,5,0},
    {0x40b0,2,4,1,5,0}, {0x40d0,0,8,0,6,0}, {0x0020,2,0,1,5,1},
    {0x0000,2,0,1,5,1}, {0x00b0,2,0,1,5,1}
};
static const uint16_t lengths[] = {12,13,31,64,1699,1700,1701,1703,1704,1705,1711,1712,1713,1735,1736,1737,2304};
static const struct sample *sample;
static uint32_t cases, checks, failure, sample_index, length, vif, station, incoming, broken;
static uint32_t allocations, sends, frees, upload_calls, upload_value, callback_error, allocated;
static uint8_t *bytes(void *p) { return p; }
void *memcpy(void *d, const void *s, size_t n) {
    uint8_t *to=d; const uint8_t *from=s; while (n--) *to++=*from++; return d;
}
void *memset(void *d, int value, size_t n) {
    uint8_t *to=d; while (n--) *to++=value; return d;
}
int memcmp(const void *a, const void *b, size_t n) {
    const uint8_t *x=a,*y=b; while (n--) { if (*x!=*y) return (int)*x-*y; ++x; ++y; } return 0;
}
void nimZeroMem(void *p, size_t n) { memset(p,0,n); }
void nimCopyMem(void *d, const void *s, size_t n) { memcpy(d,s,n); }
static void put16(void *p, uint32_t at, uint16_t v) { bytes(p)[at]=v; bytes(p)[at+1]=v>>8; }
static uint16_t get16(void *p, uint32_t at) { return bytes(p)[at]|(uint16_t)bytes(p)[at+1]<<8; }
static void put32(void *p, uint32_t at, uintptr_t v) { for (uint32_t i=0;i<4;++i) bytes(p)[at+i]=v>>(8*i); }
static uint32_t irq(void) { uint32_t v; __asm__ volatile("csrr %0,mstatus":"=r"(v)); return v&8; }
static void set_irq(uint32_t v) {
    if (v) __asm__ volatile("csrsi mstatus,8":::"memory");
    else __asm__ volatile("csrci mstatus,8":::"memory");
}
uint8_t station_current(void *p) __asm__(STATION_CURRENT);
uint8_t station_current(void *p) { return p==mpdu; }
uint32_t generation(void *p) __asm__(UPLOAD_GENERATION);
uint32_t generation(void *p) { if (p!=mpdu) ++callback_error; return 123; }
uint8_t current(void *p,uint32_t g) __asm__(UPLOAD_CURRENT);
uint8_t current(void *p,uint32_t g) { return p==mpdu && g==123; }
void *header(void *p) __asm__(MPDU_HEADER);
void *header(void *p) { return p==mpdu ? sw : 0; }
uint8_t bind_vif(void *p,uint8_t v) __asm__(BIND_VIF);
uint8_t bind_vif(void *p,uint8_t v) { if (p!=mpdu || v>=2) ++callback_error; return v<2; }
uint8_t mfp(void *p,void *env,void *frame,uint16_t n,uint8_t *upload,uint8_t *flags,uint32_t g) __asm__(MFP_IGNORE);
uint8_t mfp(void *p,void *env,void *frame,uint16_t n,uint8_t *upload,uint8_t *flags,uint32_t g) {
    if (p!=mpdu || env!=rxu_cntrl_env || frame!=buffers[0] || n!=24+sample->security+length || g!=123) ++callback_error;
    *upload=1; *flags=0; return 0;
}
uint8_t read_channel(void *p,void *out) __asm__(READ_CHANNEL);
uint8_t read_channel(void *p,void *out) {
    if (p!=mpdu || irq()!=incoming) ++callback_error;
    put32(out,0,2412u<<16); put32(out,4,0); return 1;
}
void *allocate(void *p,uint8_t destination,uint32_t n) __asm__(ALLOC_MGT);
void *allocate(void *p,uint8_t destination,uint32_t n) {
    uint32_t needed=24+sample->security+length+32;
    if (needed<68) needed=68;
    if (p!=mpdu || destination!=sample->destination || n!=needed || n>sizeof(message)-16 || irq()!=incoming) ++callback_error;
    ++allocations; allocated=n; return bytes(message)+8;
}
uint32_t upload(void *p,uint8_t allowed) __asm__(UPLOAD_MGT);
uint32_t upload(void *p,uint8_t allowed) {
    if (p!=mpdu || irq()!=incoming) ++callback_error;
    ++upload_calls; upload_value=allowed; return 0;
}
void *vif_mgmt_get_vif(uint8_t i) { return i<2 ? vif_info_tab+i*1512 : 0; }
uint8_t apm_embedded_enabled(void *p) { return p && bytes(p)[86]==2; }
uint16_t ke_state_get(uint8_t task) { if (task!=1) ++callback_error; return 3; }
uint32_t phyif_utils_decode(void *p,int8_t *rssi) {
    if (p!=bytes(sw)+40 || irq()!=incoming) ++callback_error;
    *rssi=-43; return 0;
}
void phy_get_channel_raw(void *p,uint8_t i) { (void)p; (void)i; ++callback_error; }
void me_beacon_check(uint8_t v,uint16_t n,void *p) { (void)v; (void)n; (void)p; ++callback_error; }
void ke_msg_send(void *p) { if (p!=bytes(message)+8 || irq()!=incoming) ++callback_error; ++sends; }
void ke_msg_free_payload(void *p) __asm__(FREE_MGT);
void ke_msg_free_payload(void *p) { if (p!=bytes(message)+8 || irq()!=incoming) ++callback_error; ++frees; }
void assert_warn(const char *a,const char *b,int line) { (void)a; (void)b; (void)line; ++callback_error; }
static uint8_t *wire(uint32_t at) { return at<1736 ? bytes(buffers[0])+at : bytes(buffers[2])+at-1736; }
static void prepare(void) {
    memset(sw,0,sizeof(sw)); memset(mpdu,0,sizeof(mpdu)); memset(chain,0,sizeof(chain));
    memset(buffers,0xcd,sizeof(buffers)); memset(message,0xa5,sizeof(message));
    memset(rxu_cntrl_env,0,96); memset(vif_info_tab,0,3024); memset(sta_info_tab,0,2576); memset(vif_mgmt_env,0,20);
    memset(g_bl_ops_funcs,0,sizeof(g_bl_ops_funcs));
    unexpected=callback_error=error_flag=allocations=sends=frees=upload_calls=upload_value=allocated=0;
    uint8_t *selected=vif_info_tab+vif*1512,*other=vif_info_tab+(vif^1)*1512;
    selected[86]=sample->kind; selected[87]=vif; other[86]=0; other[87]=vif^1;
    for (uint32_t i=0;i<6;++i) selected[80+i]=other[80+i]=2+i*2;
    put32(other,0,(uintptr_t)selected); put32(vif_mgmt_env,8,(uintptr_t)other);
    sta_info_tab[station*368+42]=1; sta_info_tab[station*368+39]=vif;
    put16(buffers[0],0,sample->fc); put16(buffers[0],22,0x1230);
    memcpy(bytes(buffers[0])+4,selected+80,6); memcpy(bytes(buffers[0])+16,selected+80,6);
    for (uint32_t i=0;i<6;++i) bytes(buffers[0])[10+i]=4+i*2;
    if (sample->kind==2)
        memcpy(sta_info_tab+station*368+4,bytes(buffers[0])+10,6);
    if (sample->kind==0 && ((sample->fc&0xfc)==0xb0 ||
                            (sample->fc&0xfc)==0x10 || (sample->fc&0xfc)==0x30 ||
                            (sample->fc&0xfc)==0xa0 || (sample->fc&0xfc)==0xc0 ||
                            (sample->fc&0xfc)==0xd0 || (sample->fc&0xfc)==0x80)) {
        memcpy(selected+380,bytes(buffers[0])+10,6);
        memcpy(selected+56,bytes(buffers[0])+10,6);
        memcpy(bytes(buffers[0])+16,bytes(buffers[0])+10,6);
    }
    if (sample->kind==0 && (sample->fc&0xfc)==0x80)
        memset(bytes(buffers[0])+4,0xff,6);
    for (uint32_t i=0;i<sample->security;++i) *wire(24+i)=0xd0+i;
    for (uint32_t i=0;i<length;++i) *wire(24+sample->security+i)=(i*31+7)&255;
    if ((sample->fc&0xfc)==0xd0) *wire(24+sample->security)=3;
    put32(chain[0],4,broken ? 0 : (uintptr_t)chain[1]);
    put32(chain[0],8,(uintptr_t)buffers[0]); put32(chain[0],24,(uintptr_t)buffers[0]);
    put32(chain[1],8,(uintptr_t)buffers[2]); put32(chain[1],24,(uintptr_t)buffers[2]);
    put32(sw,8,(uintptr_t)chain[0]); put16(sw,28,24+sample->security+length);
    put32(sw,64,0x6000 | (sample->unbound ? 0 : 0x02000000 | ((station+8)<<15)));
    put32(mpdu,4,(uintptr_t)sw);
    put16(rxu_cntrl_env,0,sample->fc); put16(rxu_cntrl_env,2,0x1230);
    rxu_cntrl_env[8]=24+sample->security; rxu_cntrl_env[9]=sample->unbound ? 255 : station;
    rxu_cntrl_env[10]=sample->unbound ? 255 : vif;
    uint32_t out=0;
    if (sample->whole) for (uint32_t i=0;i<24;++i) expected[out++]=*wire(i);
    for (uint32_t i=0;i<length;++i) expected[out++]=*wire(24+sample->security+i);
    if (FIXTURE_FAULT==2) expected[0]^=1;
    memcpy(saved_buffers,buffers,sizeof(buffers)); memcpy(saved_chain,chain,sizeof(chain)); set_irq(incoming);
}
#define CHECK(c,n) do { ++checks; if (!(c)) { failure=(n); return (n); } } while (0)
static int observe(void) {
    prepare(); ++cases;
    uint32_t result=rxu_mgt_frame_check(mpdu,sample->unbound ? 255 : station);
    uint8_t *payload=bytes(message)+8;
    CHECK(!unexpected && !callback_error && !error_flag,1);
    CHECK(irq()==incoming,2); CHECK(result==0,3); CHECK(allocations==1,4);
    CHECK(message[0]==0xa5a5a5a5 && message[1]==0xa5a5a5a5 &&
          bytes(message)[allocated+8]==0xa5 && bytes(message)[allocated+15]==0xa5,5);
    if (broken) {
        CHECK(sends==0 && frees==(FIXTURE_FAULT==3 ? 0u : 1u) && upload_calls==0,6);
        CHECK(!memcmp(buffers,saved_buffers,sizeof(buffers)) && !memcmp(chain,saved_chain,sizeof(chain)),7);
        return 0;
    }
    uint32_t expected_upload=sample->kind==0 && (sample->fc&0xfc)!=0xd0;
    CHECK(sends==1 && frees==0 && upload_calls==1 && upload_value==expected_upload,8);
    uint32_t size=length+(sample->whole ? 24 : 0);
    CHECK(get16(payload,0)==size+(FIXTURE_FAULT==1),9);
    CHECK(get16(payload,2)==sample->fc && payload[7]==(sample->unbound ? 255 : station) &&
          payload[8]==(FIXTURE_FAULT==4 ? (vif^1) : vif),10);
    CHECK(!memcmp(payload+32,expected,size),11);
    CHECK(get16(payload,4)==2412 && payload[6]==0 && (int8_t)payload[25]==-43,12);
    CHECK(!memcmp(buffers,saved_buffers,sizeof(buffers)) && !memcmp(chain,saved_chain,sizeof(chain)),13);
    return 0;
}
int wifi_mgt_probe_main(void) {
    for (sample_index=0;sample_index<sizeof(samples)/sizeof(samples[0]);++sample_index) {
        sample=&samples[sample_index];
        for (uint32_t l=0;l<sizeof(lengths)/sizeof(lengths[0]);++l) {
            length=lengths[l];
            for (vif=0;vif<2;++vif) for (station=0;station<=6;station+=3) for (incoming=0;incoming<=8;incoming+=8)
                for (broken=0;broken<=(24+sample->security+length>1736);++broken) {
                    int result=observe(); if (result) return result;
                }
        }
    }
    return 0;
}
static void byte(uint8_t b) { volatile uint8_t *u=(void *)0x10000000; while (!(u[5]&32)) {} u[0]=b; }
static void hex(uint32_t v) { for (int s=28;s>=0;s-=4) { uint32_t d=(v>>s)&15; byte(d<10 ? '0'+d : 'a'+d-10); } byte(' '); }
void wifi_mgt_probe_report(uint32_t result) {
    const char *text=result ? "MGTCOPY RV32 FAIL " : "MGTCOPY RV32 PASS "; while (*text) byte(*text++);
    hex(cases); hex(checks); hex(result); hex(failure); hex(sample_index); hex(length); hex(vif); hex(station);
    hex(incoming); hex(broken); hex(unexpected); hex(callback_error); hex(error_flag); byte('\n');
}
void wifi_mgt_trap_report(uint32_t cause,uint32_t pc,uint32_t value) {
    const char *text="MGTCOPY TRAP "; while (*text) byte(*text++); hex(cause); hex(pc); hex(value); byte('\n');
}
