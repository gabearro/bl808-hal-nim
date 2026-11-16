/* Actual compiled RX pipeline; current-session predicates and DMA/host transport are fixtures. */
#include <stdint.h>
#include <stddef.h>
static uint32_t unexpected, diagnostic_calls;
uintptr_t unexpected_model(void) { ++unexpected; return 0; }
uintptr_t diagnostic_model(void) { ++diagnostic_calls; return 0; }
#include "bindings.h"
struct Profile {
    uint16_t fc, length;
    uint8_t tid, keyid, group, protocol, sta, vif;
    uint8_t a1[6], a2[6], a3[6], a4[6], da[6], sa[6], material[8], mic[8];
    uint8_t foreign_da[6], foreign_mic[8];
    uint16_t last_subframe;
    uint8_t destination;
    const uint8_t *payload;
};
#include "vectors.h"
unsigned char error_flag __asm__(ERROR_FLAG);
uint8_t g_bl_ops_funcs[256];
extern uint8_t rxu_cntrl_env[96], sta_info_tab[2576], vif_info_tab[3024];
extern uint8_t apm_env[176];
extern void *wpa_cbs;
extern uint32_t rxu_cntrl_frame_handle(void *);
extern void apm_handle_eapol_input(uint8_t, const void *, uint32_t);
extern void vendor_apm_handle_eapol_input(uint8_t, const void *, uint32_t);
#define BUFFER_COUNT (AMSDU_MODE ? 5 : 3)
static uint8_t sw[100], mpdu[22], chains[BUFFER_COUNT][12], buffers[BUFFER_COUNT][1744];
static uint8_t before_buffers[BUFFER_COUNT][1744], expected_buffers[BUFFER_COUNT][1744];
static uint8_t expected_sta[2576], expected_vif[3024], before_sta[2576], before_vif[3024];
static uint8_t expected_sw[100], before_sw[100], expected_mpdu[22], before_mpdu[22];
static uint8_t before_chains[BUFFER_COUNT][12], expected_env[96];
static uint8_t eapol_storage[2320], message[32], *key;
static uint32_t allocated_length;
static uint8_t host_context[16], station_contexts[7][16], wpa_table[128];
static uint8_t before_apm[176], before_wpa[128], before_host[16], before_contexts[7][16];
static void *before_wpa_pointer;
static const struct Profile *p;
static uint32_t profile_index, cipher, stage, windowed, extra, alignment, incoming, frame_size, header_size;
static uint32_t plaintext;
static uint32_t aggregate_variant=UINT32_MAX;
static uint32_t cases, checks, failure, transfers, events, eapols, allocations, frees, messages, sends, callback_error;
static uint32_t searches;
static uint64_t received_pn;
static uint64_t accepted_pns[6];
static uint32_t accepted_count;
typedef uint32_t MemoryWord __attribute__((__may_alias__));
void *memcpy(void *dst, const void *src, size_t n) {
    uint8_t *d = dst; const uint8_t *s = src;
    if ((((uintptr_t)d | (uintptr_t)s) & 3) == 0)
        while (n >= 4) { *(MemoryWord *)d = *(const MemoryWord *)s; d+=4; s+=4; n-=4; }
    while (n--) *d++ = *s++;
    return dst;
}
void *memset(void *dst, int v, size_t n) {
    uint8_t *d = dst;
    if (((uintptr_t)d & 3) == 0) {
        uint32_t word = (uint8_t)v * 0x01010101u;
        while (n >= 4) { *(MemoryWord *)d = word; d+=4; n-=4; }
    }
    while (n--) *d++ = v;
    return dst;
}
int memcmp(const void *a, const void *b, size_t n) {
    const uint8_t *x = a, *y = b;
    if ((((uintptr_t)x | (uintptr_t)y) & 3) == 0)
        while (n >= 4 && *(const MemoryWord *)x == *(const MemoryWord *)y) { x+=4; y+=4; n-=4; }
    while (n--) { if (*x != *y) return (int)*x - *y; ++x; ++y; }
    return 0;
}
void nimZeroMem(void *p0, size_t n) { memset(p0, 0, n); }
void nimCopyMem(void *d, const void *s, size_t n) { memcpy(d, s, n); }
static void put16(uint8_t *at, uint16_t v) { at[0] = v; at[1] = v >> 8; }
static void put32(uint8_t *at, uint32_t v) {
    for (uint32_t i = 0; i < 4; ++i) at[i] = v >> (8 * i);
}
static uint32_t get32(const uint8_t *at) {
    uint32_t v = 0; for (uint32_t i = 0; i < 4; ++i) v |= (uint32_t)at[i] << (8 * i); return v;
}
static void put64(uint8_t *at, uint64_t v) { put32(at,v); put32(at+4,v>>32); }
static uint32_t irq(void) {
    uint32_t v; __asm__ volatile("csrr %0, mstatus" : "=r"(v)); return v & 8;
}
static void set_irq(uint32_t v) {
    if (v) __asm__ volatile("csrsi mstatus, 8" ::: "memory");
    else __asm__ volatile("csrci mstatus, 8" ::: "memory");
}
uint8_t station_current(void *v) __asm__(STATION_CURRENT);
uint8_t station_current(void *v) { return v == mpdu; }
void *mpdu_header(void *v) __asm__(MPDU_HEADER);
void *mpdu_header(void *v) { return v == mpdu && get32(mpdu+4) == (uintptr_t)sw ? sw : 0; }
uint32_t upload_generation(void *v) __asm__(UPLOAD_GENERATION);
uint32_t upload_generation(void *v) { if (v != mpdu) ++callback_error; return 123; }
uint8_t upload_current(void *v, uint32_t generation) __asm__(UPLOAD_CURRENT);
uint8_t upload_current(void *v, uint32_t generation) { return v == mpdu && generation == 123; }
uint8_t key_current(void *v, void *selected) __asm__(KEY_CURRENT);
uint8_t key_current(void *v, void *selected) {
    if (v != mpdu || selected != key || !key[155]) { ++callback_error; return 0; }
    return 1;
}
uint8_t transfer(void *v) __asm__(TRANSFER);
uint8_t transfer(void *v) {
    if (v != mpdu || irq() != incoming) ++callback_error;
    ++transfers; put32(mpdu+16, (uintptr_t)chains[0]); return 1;
}
uint8_t ke_state_get(uint8_t task) { (void)task; return 0; }
void ke_evt_set(uint32_t mask) {
    ++events; if (mask != 0x800000 || irq() != incoming) ++callback_error;
}
static void *allocate_eapol(uint32_t length) {
    ++allocations;
    if (length > sizeof(eapol_storage)-16 || irq() != incoming) { ++callback_error; return 0; }
    allocated_length=length;
    memset(eapol_storage, 0xcd, sizeof(eapol_storage)); return eapol_storage+8;
}
static void free_eapol(void *v) {
    ++frees; if (v != eapol_storage+8 || irq() != incoming) ++callback_error;
    for (uint32_t i=0;i<8;++i) if (eapol_storage[i]!=0xcd) ++callback_error;
    for (uint32_t i=8+allocated_length;i<sizeof(eapol_storage);++i)
        if (eapol_storage[i]!=0xcd) ++callback_error;
}
void sm_handle_eapol_input(uint8_t sta, const void *sa, const void *data, uint32_t length) {
    ++eapols;
    if (AP_MODE || sta != p->sta || length != (uint32_t)p->length - 8 || irq() != incoming ||
        memcmp(sa,p->sa,6) || memcmp(data,p->payload+8,length)) ++callback_error;
}
static uint8_t hostapd_eapol(void *context, void *station, const void *data, size_t length) {
    ++eapols;
    if (FIXTURE_FAULT==6) {
        void *temporary=context; context=station; station=temporary;
    }
    if (!AP_MODE || context!=host_context || station!=station_contexts[p->sta] ||
        length!=(uint32_t)p->length-8 || irq()!=incoming || memcmp(data,p->payload+8,length))
        ++callback_error;
    return profile_index&1;
}
uint32_t hal_machw_search_addr(const void *address, uint32_t unused) {
    const uint8_t *expected=stage==6 ? p->foreign_da : p->da;
    ++searches;
    if (!AP_MODE || unused || (expected[0]&1) || memcmp(address,expected,6) || irq()!=incoming)
        ++callback_error;
    return stage==6 ? 255 : p->destination;
}
static void ap_ready(void) {
    put32(apm_env+172,(uintptr_t)host_context);
    wpa_cbs=wpa_table;
    put32(wpa_table+44,(uintptr_t)hostapd_eapol);
    put32(sta_info_tab+p->sta*368+364,(uintptr_t)station_contexts[p->sta]);
    sta_info_tab[p->sta*368+42]=1;
}
static void snapshot_ap(void) {
    memcpy(before_apm,apm_env,176); memcpy(before_wpa,wpa_table,sizeof(wpa_table));
    memcpy(before_host,host_context,sizeof(host_context));
    memcpy(before_contexts,station_contexts,sizeof(station_contexts));
    before_wpa_pointer=wpa_cbs;
}
static uint32_t ap_unchanged(void) {
    return !memcmp(before_apm,apm_env,176) && !memcmp(before_wpa,wpa_table,sizeof(wpa_table)) &&
        !memcmp(before_host,host_context,sizeof(host_context)) &&
        !memcmp(before_contexts,station_contexts,sizeof(station_contexts)) && wpa_cbs==before_wpa_pointer;
}
void *ke_msg_alloc(uint16_t id, uint8_t dst, uint8_t src, uint32_t length) {
    ++messages;
    if (id != 0xc04 || dst != 9 || src != 3 || length != 24 || irq() != incoming) ++callback_error;
    memset(message,0xcd,sizeof(message)); memset(message,0,24); return message;
}
void ke_msg_send(void *v) {
    ++sends;
    uint8_t expected[32]; memset(expected,0xcd,sizeof(expected)); memset(expected,0,24);
    memcpy(expected,sta_info_tab + p->sta*368+4,6); put64(expected+8,received_pn);
    expected[16]=p->group; expected[17]=p->keyid; expected[18]=p->vif;
    if (v != message || memcmp(message,expected,sizeof(expected)) || irq() != incoming) ++callback_error;
}
static uint32_t mac_length(uint16_t fc) {
    uint32_t len = (fc & 0x300) == 0x300 ? 30 : 24;
    if (fc & 0x80) len += (fc & 0x8000) ? 6 : 2;
    return len;
}
static uint8_t *frame_byte(uint32_t offset) { return buffers[offset/1736] + alignment + offset%1736; }
static uint8_t *expected_byte(uint32_t offset) { return expected_buffers[offset/1736] + alignment + offset%1736; }
static void initialize_key(void) {
    memset(sta_info_tab,0xa5,2576); memset(vif_info_tab,0xa5,3024);
    uint8_t *sta = sta_info_tab + p->sta*368;
    sta[39]=p->vif; sta[42]=1; sta[72]=2; put16(sta+70,0x888e);
    memcpy(sta+4,p->a2,6);
    for (uint32_t i=0;i<9;++i) put16(sta+336+i*2,0xffff);
    uint8_t *vif = vif_info_tab+p->vif*1512;
    static const uint8_t local_mac[6]={2,1,2,3,4,5};
    vif[86]=AP_MODE ? 2 : 0; vif[87]=p->vif; memcpy(vif+80,local_mac,6);
    if (AP_MODE || AMSDU_MODE) vif[497]=2;
    if (AP_MODE) {
        memset(apm_env,0,176); apm_env[89]=p->vif;
        memset(wpa_table,0xcd,sizeof(wpa_table)); ap_ready();
    }
    key = p->group ? vif+528+p->keyid*160 : sta+80;
    memset(key,0,128); put32(key+128,0x11223344); put32(key+132,0x5566);
    for (uint32_t i=0;i<8;++i) { key[136+i]=p->material[i]^255; key[144+i]=p->material[i]; }
    if (FIXTURE_FAULT==1) memcpy(key+144,key+136,8);
    key[152]=cipher; key[153]=p->keyid; key[154]=p->group ? 4*p->vif+p->keyid : 8+p->sta;
    key[155]=1; key[156]=windowed; accepted_count=0;
}
static void load_frame(uint64_t pn, uint16_t sequence, uint32_t invalid) {
    uint16_t wire_fc=plaintext ? p->fc&~0x4000u : p->fc;
    received_pn=pn; header_size=mac_length(wire_fc)+(plaintext ? 0 : cipher==0 ? 4 : 8);
    frame_size=header_size+p->length+(cipher==1 && !plaintext ? 8 : 0);
    if (AP_MODE) {
        put32(rxu_cntrl_env+64,0); put32(rxu_cntrl_env+68,0);
    } else memset(rxu_cntrl_env,0,96);
    memset(sw,0,sizeof(sw)); memset(mpdu,0,sizeof(mpdu));
    memset(buffers,0xcd,sizeof(buffers)); memset(chains,0,sizeof(chains));
    uint8_t *frame = frame_byte(0);
    put16(frame,wire_fc); put16(frame+22,sequence);
    memcpy(frame+4,p->a1,6); memcpy(frame+10,p->a2,6); memcpy(frame+16,p->a3,6);
    if ((p->fc&0x300)==0x300) memcpy(frame+24,p->a4,6);
    if (p->fc&0x80) put16(frame+((p->fc&0x300)==0x300 ? 30 : 24),p->tid|(AMSDU_MODE ? 0x80 : 0));
    if (!plaintext) {
        uint32_t security_length=cipher==0 ? 4 : 8;
        uint8_t *iv=frame+header_size-security_length; memset(iv,0,security_length);
        if (cipher==1) {
            iv[0]=pn>>8; iv[1]=(iv[0]|0x20)&0x7f; iv[2]=pn;
        } else { iv[0]=pn; iv[1]=pn>>8; }
        iv[3]=(p->keyid<<6)|((invalid && cipher==2) ? 0 : 0x20);
        if (cipher!=0) for (uint32_t i=0;i<4;++i) iv[4+i]=pn>>(16+i*8);
    }
    for (uint32_t i=0;i<p->length;++i) *frame_byte(header_size+i)=p->payload[i];
    if (cipher==1 && !plaintext) {
        for (uint32_t i=0;i<8;++i) *frame_byte(header_size+p->length+i)=p->mic[i];
        if (invalid) *frame_byte(header_size+p->length+p->keyid)^=1;
    }
    if (AMSDU_MODE && aggregate_variant!=UINT32_MAX) {
        uint32_t last=header_size+p->last_subframe;
        if (aggregate_variant==3) --frame_size;
        if (aggregate_variant==4) { *frame_byte(header_size+12)=0; *frame_byte(header_size+13)=0; }
        if (aggregate_variant==5) { *frame_byte(last+12)=9; *frame_byte(last+13)=1; }
        if (aggregate_variant==6) *frame_byte(last+6)|=1;
        if (aggregate_variant==7) {
            static const uint8_t snap_destination[6]={0xaa,0xaa,3,0,0,0};
            for (uint32_t i=0;i<6;++i) *frame_byte(last+i)=snap_destination[i];
        }
        if (aggregate_variant==8) frame[4]|=1;
        if (aggregate_variant==13) *frame_byte(last+(AP_MODE ? 6 : 0))=0x44;
        if (aggregate_variant==14) ++frame_size;
    }
    for (uint32_t i=0;i<BUFFER_COUNT;++i) {
        put32(chains[i]+8,(uintptr_t)(buffers[i]+alignment));
        if ((i+1)*1736<frame_size) put32(chains[i]+4,(uintptr_t)chains[i+1]);
    }
    if (FIXTURE_FAULT==2 && frame_size>1736) put32(chains[0]+4,(uintptr_t)chains[0]);
    put32(sw+8,(uintptr_t)chains[0]); put16(sw+28,frame_size);
    put32(sw+64,0x02002000|((p->sta+8)<<15)|(plaintext ? 0 : cipher==0 ? 20 : cipher==1 ? 24 : 28)|(p->group ? 0x400 : 0));
    put32(mpdu+4,(uintptr_t)sw);
    transfers=events=eapols=allocations=frees=messages=sends=callback_error=unexpected=error_flag=searches=0;
}
#define CHECK(c,code) do { if (!(c)) { failure=code; return __LINE__; } ++checks; } while (0)
static int observe(uint64_t pn, uint16_t sequence, uint32_t invalid, uint32_t accepted) {
    load_frame(pn,sequence,invalid);
    if (stage==6) {
        memcpy(frame_byte((p->fc&0x100) ? 16 : 4),p->foreign_da,6);
        if (cipher==1 && !plaintext)
            for (uint32_t i=0;i<8;++i) *frame_byte(header_size+p->length+i)=p->foreign_mic[i];
    }
    memcpy(before_buffers,buffers,sizeof(buffers)); memcpy(expected_buffers,buffers,sizeof(buffers));
    memcpy(before_sta,sta_info_tab,2576); memcpy(before_vif,vif_info_tab,3024);
    memcpy(expected_sta,sta_info_tab,2576); memcpy(expected_vif,vif_info_tab,3024);
    memcpy(before_sw,sw,sizeof(sw)); memcpy(expected_sw,sw,sizeof(sw));
    memcpy(before_mpdu,mpdu,sizeof(mpdu)); memcpy(expected_mpdu,mpdu,sizeof(mpdu));
    memcpy(before_chains,chains,sizeof(chains)); memset(expected_env,0,sizeof(expected_env));
    put16(expected_env,plaintext ? p->fc&~0x4000u : p->fc);
    put16(expected_env+2,sequence); put16(expected_env+4,sequence>>4);
    expected_env[7]=p->tid; expected_env[8]=header_size; expected_env[9]=p->sta;
    expected_env[10]=p->vif; expected_env[11]=255; put32(expected_env+24,get32(sw+64));
    memcpy(expected_env+36,stage==6 ? p->foreign_da : p->da,6); memcpy(expected_env+42,p->sa,6);
    if (AMSDU_MODE && aggregate_variant==8 && !(p->fc&0x100)) expected_env[36]|=1;
    uint32_t lookup=AP_MODE && !(expected_env[36]&1);
    if (lookup) expected_env[11]=stage==6 ? 255 : p->destination;
    if (AP_MODE) snapshot_ap();
    if (cipher==2 && invalid && !plaintext) expected_env[8]-=8;
    else if (!plaintext && cipher!=0) {
        put64(expected_env+16,pn); put32(expected_env+32,(uintptr_t)key);
        expected_env[48]=cipher==1 ? 3 : 2;
    }
    set_irq(incoming);
    uint32_t result=rxu_cntrl_frame_handle(mpdu);
    if (FIXTURE_FAULT==3 && accepted) key[p->tid*16+8]^=1;
    if (FIXTURE_FAULT==4) buffers[0][1743]^=1;
    if (FIXTURE_FAULT==5 && accepted && p->protocol!=1) sw[79]^=1;
    if (FIXTURE_FAULT==7 && accepted) sw[76]^=1;
    CHECK(!unexpected && !callback_error && !error_flag,1);
    CHECK(irq()==incoming,2);
    uint32_t eapol=p->protocol==1;
    CHECK(result==(accepted && !eapol),3);
    CHECK(transfers==(accepted && !eapol) && eapols==(accepted && eapol),4);
    CHECK(events==(accepted && !eapol),5);
    uint32_t allocated=accepted && eapol && header_size+p->length>1736;
    CHECK(allocations==allocated && frees==allocated,6);
    uint32_t bad_mic=cipher==1 && invalid && !plaintext;
    CHECK(messages==bad_mic && sends==bad_mic,7);
    uint32_t flags=(p->fc&0x300)==0x300 ? 4 : 0;
    put32(expected_sw+76,flags);
    if (accepted) {
      if (!plaintext && cipher!=0) {
        accepted_pns[accepted_count++]=pn;
        uint64_t highest=0;
        for (uint32_t i=0;i<accepted_count;++i) if (accepted_pns[i]>highest) highest=accepted_pns[i];
        uint8_t *expected_key=p->group ? expected_vif+p->vif*1512+528+p->keyid*160 : expected_sta+p->sta*368+80;
        uint8_t *counter=expected_key+p->tid*16;
        put64(counter,highest+1);
        if (windowed) {
            put64(counter+8,0);
            for (uint32_t i=0;i<accepted_count;++i) {
                uint64_t n=accepted_pns[i]+1;
                uint8_t *bank=counter+8+((n>>5)&1)*4;
                put32(bank,get32(bank)|(1u<<(n&31)));
            }
        }
      }
        put16(expected_sta+p->sta*368+((p->fc&0x80) ? 338+p->tid*2 : 336),sequence);
        if (eapol) put16(expected_sw+28,frame_size-(cipher==1 && !plaintext ? 8 : 0));
        else {
            uint32_t ethernet=p->protocol!=4;
            uint32_t strip=AMSDU_MODE ? header_size : header_size-(ethernet ? 6 : 14);
            put32(expected_sw+84,strip);
            put16(expected_sw+28,p->length+(AMSDU_MODE ? 0 : ethernet ? 6 : 14));
            flags|=((uint32_t)expected_env[11]<<24)|((uint32_t)p->sta<<16)|((uint32_t)p->vif<<8);
            if (AMSDU_MODE) flags|=1;
            if (p->fc&0x80) flags|=(uint32_t)p->tid<<4;
            put32(expected_sw+76,flags);
            if (!AMSDU_MODE) {
                for (uint32_t i=0;i<6;++i) { *expected_byte(strip+i)=p->da[i]; *expected_byte(strip+6+i)=p->sa[i]; }
                if (!ethernet) { *expected_byte(strip+12)=p->length>>8; *expected_byte(strip+13)=p->length; }
            }
            put32(expected_mpdu+16,(uintptr_t)chains[0]); expected_mpdu[20]=3;
            expected_env[49]=!AMSDU_MODE && !ethernet; expected_env[50]=strip;
            put32(expected_env+64,(uintptr_t)mpdu); put32(expected_env+68,(uintptr_t)mpdu);
            CHECK(get32(rxu_cntrl_env+64)==(uintptr_t)mpdu && get32(rxu_cntrl_env+68)==(uintptr_t)mpdu,8);
        }
    }
    CHECK(memcmp(sta_info_tab,expected_sta,2576)==0 && memcmp(vif_info_tab,expected_vif,3024)==0,9);
    CHECK(memcmp(sw,expected_sw,sizeof(sw))==0,10);
    CHECK(memcmp(mpdu,expected_mpdu,sizeof(mpdu))==0,11);
    CHECK(memcmp(buffers,expected_buffers,sizeof(buffers))==0,12);
    CHECK(memcmp(chains,before_chains,sizeof(chains))==0,13);
    CHECK(memcmp(rxu_cntrl_env,expected_env,sizeof(expected_env))==0,14);
    if (AP_MODE) {
        CHECK(searches==lookup,15);
        CHECK(ap_unchanged(),16);
    }
    ++cases; return 0;
}
static int check_ap_wrapper(void) {
    for (incoming=0;incoming<=8;incoming+=8)
    for (uint32_t variant=0;variant<10;++variant) {
        ap_ready();
        uint8_t station=p->sta;
        const void *data=p->payload+8;
        uint32_t length=p->length-8;
        if (variant==1) put32(apm_env+172,0);
        if (variant==2) wpa_cbs=0;
        if (variant==3) put32(wpa_table+44,0);
        if (variant==4) put32(sta_info_tab+p->sta*368+364,0);
        if (variant==5) sta_info_tab[p->sta*368+42]=0;
        if (variant==6) station=7;
        if (variant==7) station=255;
        if (variant==8) data=0;
        if (variant==9) length=0;
        snapshot_ap(); memcpy(before_sta,sta_info_tab,2576); memcpy(before_vif,vif_info_tab,3024);
        memcpy(expected_env,rxu_cntrl_env,96);
        eapols=callback_error=unexpected=error_flag=0;
        set_irq(incoming);
        apm_handle_eapol_input(station,data,length);
        CHECK(eapols==(variant==0) && !callback_error && !unexpected && !error_flag,17);
        CHECK(ap_unchanged() && !memcmp(sta_info_tab,before_sta,2576) &&
              !memcmp(vif_info_tab,before_vif,3024) && !memcmp(rxu_cntrl_env,expected_env,96),18);
        CHECK(irq()==incoming,19);
        if (variant<=1) {
            eapols=0;
            vendor_apm_handle_eapol_input(station,data,length);
            CHECK(eapols==(variant==0) && !callback_error && !unexpected && !error_flag && irq()==incoming,20);
            CHECK(ap_unchanged() && !memcmp(sta_info_tab,before_sta,2576) &&
                  !memcmp(vif_info_tab,before_vif,3024) && !memcmp(rxu_cntrl_env,expected_env,96),21);
        }
    }
    return 0;
}
static int check_plaintext_eapol(void) {
    plaintext=1; cipher=2; windowed=0;
    for (alignment=0;alignment<4;++alignment)
    for (incoming=0;incoming<=8;incoming+=8)
    for (uint32_t port=0;port<3;++port)
    for (uint32_t foreign=0;foreign<2;++foreign) {
        initialize_key();
        key[155]=0;
        put64(key+p->tid*16,0x123456789aULL);
        sta_info_tab[p->sta*368+72]=port;
        stage=foreign ? 6 : 7;
        extra=port|(alignment<<8)|(incoming<<16);
        int result=observe(0,0x12a0+port*32+foreign*16,0,port!=0 && !foreign);
        if (result) return result;
    }
    plaintext=0;
    return 0;
}
static int check_aggregate_admission(void) {
    windowed=0;
    for (alignment=0;alignment<4;++alignment)
    for (incoming=0;incoming<=8;incoming+=8)
    for (aggregate_variant=0;aggregate_variant<16;++aggregate_variant) {
        cipher=aggregate_variant==9 ? 1 : aggregate_variant==10 ? 0 : 2;
        plaintext=aggregate_variant==11 || aggregate_variant==12;
        initialize_key();
        sta_info_tab[p->sta*368+72]=aggregate_variant<2 ? aggregate_variant : 2;
        if (aggregate_variant==12) vif_info_tab[p->vif*1512+497]=0;
        uint32_t accepted=aggregate_variant==2 || aggregate_variant==12 || aggregate_variant==15 ||
            (aggregate_variant==13 && (p->fc&0x300)==0x300);
        stage=8+aggregate_variant;
        extra=aggregate_variant|(alignment<<8)|(incoming<<16);
        int result=observe(7,0x12a0+aggregate_variant*16,0,accepted);
        if (result) return result;
    }
    plaintext=0; aggregate_variant=UINT32_MAX;
    return 0;
}
int wifi_pipeline_probe_main(void) {
    put32(g_bl_ops_funcs+184,(uintptr_t)allocate_eapol); put32(g_bl_ops_funcs+188,(uintptr_t)free_eapol);
    memset(rxu_cntrl_env,0,96);
    memset(host_context,0x5a,sizeof(host_context)); memset(station_contexts,0x5a,sizeof(station_contexts));
    static const uint64_t bases[]={0,1,0xfffffffeULL,(1ULL<<37)-1};
    for (profile_index=0;profile_index<PROFILE_COUNT;++profile_index) {
        p=profiles+profile_index;
        for (cipher=AMSDU_MODE ? 2 : 1;cipher<=2;++cipher) for (windowed=0;windowed<2;++windowed)
        for (incoming=0;incoming<=8;incoming+=8) for (alignment=0;alignment<4;++alignment)
        for (uint32_t b=0;b<4;++b) {
            extra=b|(alignment<<8)|(incoming<<16); initialize_key();
            for (stage=0;stage<6;++stage) {
                uint32_t invalid=stage==0 || stage==3;
                uint64_t pn=stage==0 || stage==3 || stage==4 ? bases[b]+10 : stage==5 ? bases[b]+5 : bases[b];
                uint32_t accepted=(stage==1 && (cipher==1 || pn!=0)) || stage==4 || (stage==5 && windowed);
                int result=observe(pn,0x1230+stage*16,invalid,accepted);
                if (result) return result;
            }
            if (p->protocol==1) {
                stage=6;
                int result=observe(bases[b]+11,0x1290,0,0);
                if (result) return result;
            }
        }
        if (AP_MODE && p->protocol==1) {
            int result=check_ap_wrapper();
            if (result) return result;
            result=check_plaintext_eapol();
            if (result) return result;
        }
        if (AMSDU_MODE) {
            int result=check_aggregate_admission();
            if (result) return result;
        }
    }
    return 0;
}
static void byte(uint8_t b) {
    volatile uint8_t *u=(volatile uint8_t *)0x10000000;
    while (!(u[5]&32)) {} u[0]=b;
}
static void hex(uint32_t n) {
    for (int s=28;s>=0;s-=4) { uint32_t d=(n>>s)&15; byte(d<10 ? '0'+d : 'a'+d-10); }
    byte(' ');
}
void wifi_pipeline_probe_report(uint32_t result) {
    const char *t=result ? "RXPIPE RV32 FAIL " : "RXPIPE RV32 PASS ";
    while (*t) byte(*t++);
    hex(cases); hex(checks); hex(result); hex(failure); hex(profile_index); hex(cipher); hex(stage); hex(windowed); hex(extra);
    hex(unexpected); hex(callback_error); hex(error_flag); byte('\n');
}
void wifi_pipeline_trap_report(uint32_t cause,uint32_t pc,uint32_t value) {
    const char *t="RXPIPE TRAP "; while (*t) byte(*t++);
    hex(cause); hex(pc); hex(value); byte('\n');
}
