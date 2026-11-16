/* Normal BIP, RX predicates and libc; observers wrap the original memory code. */
#include <stdint.h>
#include <stddef.h>
static uint32_t unexpected;
#include "bindings.h"
extern uint8_t rx_dma_hdrdesc[4100], rx_payload_desc[2132], rx_swdesc_tab[984];
extern uint8_t rx_payload_desc_buffer[71176], vif_info_tab[3024], sta_info_tab[2576];
extern uint32_t upload_epochs[41] __asm__(UPLOAD_EPOCHS);
extern uint32_t vif_epochs[2] __asm__(VIF_EPOCHS);
extern uint32_t station_epochs[5] __asm__(STATION_EPOCHS);
extern uint64_t key_clock __asm__(KEY_CLOCK), key_changes[19] __asm__(KEY_CHANGES);
extern uint8_t error_flag __asm__(ERROR_FLAG);
extern void capture_station(void *,uint32_t) __asm__(CAPTURE_STATION);
extern uint8_t admit(void *,void **) __asm__(ADMIT);
extern void *firmware_memcpy(void *,const void *,size_t);
extern void *firmware_memset(void *,int,size_t);
extern int memcmp(const void *,const void *,size_t);
extern uint8_t bip_call_measured(void *,void *,void *,uint16_t,uint8_t *,uint8_t *,uint32_t);
volatile uint32_t bip_stack_used, bip_stack_guard;
struct profile { uint16_t length; uint8_t header; uint64_t ipn; const uint8_t *data[2]; };
#include "vectors.h"
static uint32_t cases, checks, failure, profile_index, key, vif, station, incoming, stage, peak_stack;
static uint32_t in_policy, hooks, observer_error, captured, descriptor_index, head_index, tail_index, poison_index;
static uint8_t *mpdu, *sw, *head, *tail, *first, *last, *poison, *selected;
static uint8_t env[96], flat[4096], saved_flat[4096], saved_first[1736], saved_last[1736], saved_poison[1736];
static uint8_t saved_sw[100], saved_mpdu[24], saved_head[52], saved_tail[52], saved_vifs[3024];
static const struct profile *input;
static uint8_t *bytes(void *p) { return p; }
static uint64_t get64(const void *p) {
    const uint8_t *b=p; uint64_t v=0; for (uint32_t i=0;i<8;++i) v|=(uint64_t)b[i]<<(8*i); return v;
}
static void put64(void *p,uint64_t v) { for (uint32_t i=0;i<8;++i) bytes(p)[i]=v>>(8*i); }
static void put32(void *p,uint32_t at,uintptr_t v) { for (uint32_t i=0;i<4;++i) bytes(p)[at+i]=v>>(8*i); }
static void put16(void *p,uint32_t at,uint16_t v) { bytes(p)[at]=v; bytes(p)[at+1]=v>>8; }
static uint32_t irq(void) { uint32_t v; __asm__ volatile("csrr %0,mstatus":"=r"(v)); return v&8; }
static void set_irq(uint32_t v) {
    if (v) __asm__ volatile("csrsi mstatus,8":::"memory");
    else __asm__ volatile("csrci mstatus,8":::"memory");
}
static uint32_t station_flags(void) { return 0x02000000 | ((station+8)<<15); }
static void memory_observation(const void *source,size_t n) {
    if (!in_policy) return;
    if (n==16 && (memcmp(first,saved_first,1736) || memcmp(last,saved_last,1736) ||
                  memcmp(poison,saved_poison,1736) || memcmp(flat,saved_flat,sizeof(flat)))) observer_error|=1;
    uint32_t first_chunk=input->length-input->header-8;
    if (first_chunk>64) first_chunk=64;
    /* Chained body copy, or the flat digest's output copy, brackets hash work. */
    uint32_t boundary=stage==18 ? n==16 : source==first+input->header && n==first_chunk;
    if (boundary && hooks==0 && ((stage>=7 && stage<=11) || stage==18)) {
        ++hooks;
        if (irq()!=incoming) observer_error|=2;
        if (stage==7) capture_station(mpdu,station_flags());
        if (stage==8 || stage==18) { key_clock=2; key_changes[7+vif*6+key]=2; }
        if (stage==9) ++vif_epochs[vif];
        if (stage==10) ++vif_epochs[vif^1];
        if (stage==11) put64(selected,input->ipn+8);
        if (irq()!=incoming) observer_error|=2;
    }
}
void *memcpy(void *d,const void *s,size_t n) {
    memory_observation(s,n);
    return firmware_memcpy(d,s,n);
}
void *memset(void *d,int value,size_t n) {
    memory_observation(0,n);
    return firmware_memset(d,value,n);
}
static uint8_t *wire(uint32_t at) { return at<1736 ? first+at : last+at-1736; }
static void prepare(void) {
    in_policy=0; hooks=observer_error=unexpected=error_flag=0;
    descriptor_index=profile_index&1 ? 40 : 0;
    head_index=profile_index&1 ? 39 : 0;
    tail_index=profile_index&1 ? 1 : 40;
    poison_index=head_index+1;
    mpdu=rx_swdesc_tab+24*descriptor_index; sw=rx_dma_hdrdesc+100*descriptor_index;
    head=rx_payload_desc+52*head_index; tail=rx_payload_desc+52*tail_index;
    first=rx_payload_desc_buffer+1736*head_index; last=rx_payload_desc_buffer+1736*tail_index;
    poison=rx_payload_desc_buffer+1736*poison_index;
    memset(env,0,sizeof(env)); memset(flat,0xcd,sizeof(flat));
    memset(first,0xcd,1736); memset(last,0xcd,1736); memset(poison,0xcd,1736);
    memset(mpdu,0,24); memset(sw,0,100); memset(head,0,52); memset(tail,0,52);
    memset(vif_info_tab,0,3024); memset(sta_info_tab,0,2576);
    memset(vif_epochs,0,8); memset(station_epochs,0,20); memset(key_changes,0,19*8);
    memset(upload_epochs,0,41*4); key_clock=1;
    if (profile_index&2) upload_epochs[descriptor_index]=UINT32_MAX;
    selected=vif_info_tab+vif*1512+528+key*160;
    selected[152]=5; selected[153]=key; selected[155]=1;
    for (uint32_t i=0;i<16;++i) selected[136+i]=i;
    put32(vif_info_tab+vif*1512,1492,(uintptr_t)selected);
    sta_info_tab[station*368+42]=1; sta_info_tab[station*368+39]=vif;
    put32(sta_info_tab+station*368,308,8);
    memcpy(flat,input->data[key-4],input->length);
    for (uint32_t i=0;i<input->length;++i) *wire(i)=flat[i];
    put32(head,4,(uintptr_t)tail); put32(head,8,(uintptr_t)first); put32(head,24,(uintptr_t)first);
    put32(tail,8,(uintptr_t)last); put32(tail,24,(uintptr_t)last);
    put32(head,16,input->length<=1736); put32(tail,16,1);
    put32(sw,8,(uintptr_t)head); put32(sw,12,(uintptr_t)mpdu); put16(sw,28,input->length);
    put32(mpdu,4,(uintptr_t)sw); put32(sw,64,0x6000|station_flags());
    put16(env,0,flat[0]|(uint16_t)flat[1]<<8); env[8]=input->header;
    env[9]=station; env[10]=vif; env[36]=1;
    set_irq(incoming); capture_station(mpdu,station_flags()); captured=upload_epochs[descriptor_index];
    void *admitted=0;
    if (admit(mpdu,&admitted)!=2 || admitted!=sw) unexpected=1;
    if (stage==1) put64(selected,input->ipn+1);
    if (stage==2) *wire(input->length-1)^=1;
    if (stage==3) *wire(input->length-18)^=1;
    if (stage==4) *wire(input->length-17)^=1;
    if (stage==5) selected[155]=0;
    if (stage==6) capture_station(mpdu,station_flags());
    if (stage==12) {
        if (input->length>1736) put32(head,4,0); else put32(sw,8,0);
    }
    if (stage==13) put32(mpdu,4,0);
    if (stage==14) ++station_epochs[station];
    if (stage==16) flat[input->length-1]^=1;
    if (stage==17) flat[input->length-18]^=1;
    memcpy(saved_flat,flat,sizeof(flat)); memcpy(saved_first,first,1736);
    memcpy(saved_last,last,1736); memcpy(saved_poison,poison,1736);
    memcpy(saved_mpdu,mpdu,24); memcpy(saved_sw,sw,100); memcpy(saved_head,head,52); memcpy(saved_tail,tail,52);
    memcpy(saved_vifs,vif_info_tab,3024);
}
#define CHECK(c,n) do { ++checks; if (!(c)) { failure=(n); return (n); } } while (0)
static int observe(void) {
    prepare(); ++cases; uint8_t upload=1,flags=0xa0;
    in_policy=1;
    uint8_t result=bip_call_measured(stage>=15 ? 0 : mpdu,env,stage>=15 ? flat : first,
                                   input->length,&upload,&flags,captured);
    in_policy=0;
    if (FIXTURE_FAULT==3) saved_first[0]^=1;
    if (bip_stack_used>peak_stack) peak_stack=bip_stack_used;
    uint32_t accept=stage==0 || stage==10 || stage==15;
    uint64_t pn=accept || stage==1 ? input->ipn+1 : stage==11 ? input->ipn+8 : 0;
    uint32_t expected_hooks=(stage>=7 && stage<=11) || stage==18;
    CHECK(!unexpected && !observer_error && !error_flag,1);
    CHECK(irq()==incoming,2);
    CHECK(result==(FIXTURE_FAULT==1 ? accept : !accept),3);
    CHECK(upload==accept && flags==0xa0,4);
    CHECK(get64(selected)==(pn^(FIXTURE_FAULT==2)),5);
    CHECK(!memcmp(first,saved_first,1736) && !memcmp(last,saved_last,1736) &&
          !memcmp(poison,saved_poison,1736) && !memcmp(flat,saved_flat,sizeof(flat)),6);
    uint32_t at=(uint32_t)(selected-vif_info_tab);
    CHECK(!memcmp(vif_info_tab,saved_vifs,at) && !memcmp(selected+8,saved_vifs+at+8,3024-at-8),7);
    CHECK(!memcmp(sw,saved_sw,100) && !memcmp(mpdu,saved_mpdu,24) &&
          !memcmp(head,saved_head,52) && !memcmp(tail,saved_tail,52),8);
    CHECK(hooks==expected_hooks,9);
    CHECK(upload_epochs[descriptor_index]==captured+(stage==6 || stage==7) &&
          key_clock==(uint64_t)(1+(stage==8 || stage==18)) &&
          vif_epochs[vif]==(stage==9) && vif_epochs[vif^1]==(stage==10) &&
          station_epochs[station]==(stage==14),10);
    CHECK(bip_stack_guard && FIXTURE_FAULT!=4,11);
    CHECK(bip_stack_used>0 && bip_stack_used<=2048,12);
    return 0;
}
int wifi_bip_probe_main(void) {
    for (profile_index=0;profile_index<PROFILE_COUNT;++profile_index) {
        input=&profiles[profile_index];
        for (key=4;key<=5;++key) for (vif=0;vif<2;++vif) for (station=0;station<=4;station+=4)
            for (incoming=0;incoming<=8;incoming+=8) for (stage=0;stage<19;++stage) {
                int result=observe(); if (result) return result;
            }
    }
    return 0;
}
static void byte(uint8_t b) { volatile uint8_t *u=(void *)0x10000000; while (!(u[5]&32)) {} u[0]=b; }
static void hex(uint32_t v) { for (int s=28;s>=0;s-=4) { uint32_t d=v>>s&15; byte(d<10 ? '0'+d : 'a'+d-10); } byte(' '); }
void wifi_bip_probe_report(uint32_t result) {
    const char *s=result ? "BIPRX RV32 FAIL " : "BIPRX RV32 PASS "; while (*s) byte(*s++);
    hex(cases); hex(checks); hex(result); hex(failure); hex(profile_index); hex(key); hex(vif); hex(station);
    hex(incoming); hex(stage); hex(unexpected); hex(observer_error); hex(error_flag); hex(peak_stack); byte('\n');
}
void wifi_bip_trap_report(uint32_t cause,uint32_t pc,uint32_t value) {
    const char *s="BIPRX TRAP "; while (*s) byte(*s++); hex(cause); hex(pc); hex(value); byte('\n');
}
