/*
 * Bare-metal support glue for the BL808 vendor WiFi blob.
 *
 * The Bouffalo WiFi host driver expects the SDK OS adapter, lwIP netif API,
 * and a handful of platform hooks.  The HAL examples run without FreeRTOS, so
 * this file supplies the minimal services needed to drive the vendor firmware
 * from the M0 core and poll its IPC interrupt path explicitly.
 */

#include <stdarg.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>

#include <bl60x_fw_api.h>
#include <bl_os_adapter/bl_os_adapter.h>
#include <lwip/etharp.h>
#include <lwip/ip4_addr.h>
#include <lwip/netif.h>
#include <lwip/netifapi.h>
#include <lwip/pbuf.h>
#include <lwip/tcpip.h>

/* Iter 2.A.0 step 2: vendor lwIP's lwipopts.h leaves LWIP_NETIF_API
 * undefined, so vendor netifapi.h does not declare these typedefs. SDK lwIP
 * defines them. When vendor headers win the include race (Task 3 onward),
 * declare them locally so this file's netifapi_netif_common signature
 * compiles. Today (SDK headers active) this block is dead code. */
#ifndef LWIP_NETIF_API
#define LWIP_NETIF_API 0
#endif
#if !LWIP_NETIF_API
typedef void  (*netifapi_void_fn)(struct netif *netif);
typedef err_t (*netifapi_errt_fn)(struct netif *netif);
#endif

#include "../../build/bl_iot_sdk_b773b3f/components/network/wifi_manager/bl60x_wifi_driver/bl_main.h"
#include "../../build/bl_iot_sdk_b773b3f/components/network/wifi_manager/bl60x_wifi_driver/bl_msg_tx.h"
#include "../../build/bl_iot_sdk_b773b3f/components/network/wifi_manager/bl60x_wifi_driver/bl_rx.h"
#include "../../build/bl_iot_sdk_b773b3f/components/network/wifi_manager/bl60x_wifi_driver/wifi_mgmr.h"
#include "../../build/bl_iot_sdk_b773b3f/components/network/wifi_manager/bl60x_wifi_driver/include/wifi_mgmr_ext.h"

extern void hw_validation_log_byte(uint8_t b) __attribute__((weak));

#ifdef netifapi_netif_set_default
#undef netifapi_netif_set_default
#endif
#ifdef netifapi_netif_set_up
#undef netifapi_netif_set_up
#endif

extern void *malloc(size_t size);
extern void free(void *ptr);
extern void *calloc(size_t count, size_t size);
extern void *realloc(void *ptr, size_t size);
extern size_t tlsf_get_used(void);
extern size_t tlsf_get_total(void);
extern size_t tlsf_get_largest_free(void);
extern size_t tlsf_get_alloc_fail_count(void);
extern void bl808_register_trap_handler(uint32_t irq, void (*handler)(void));
extern void bl808_enable_peripheral_irq(uint32_t irq, uint8_t level);
extern void bl808_disable_peripheral_irq(uint32_t irq);

extern int bl606a0_wifi_init(wifi_conf_t *conf);
extern err_t bl606a0_wifi_netif_init(struct netif *netif);
extern int bl_main_if_add(int is_sta, struct netif *netif, uint8_t *vif_index);
extern int bl_main_scan(struct netif *netif, uint16_t *fixed_channels,
                        uint16_t channel_num, struct mac_addr *bssid,
                        struct mac_ssid *ssid, uint8_t scan_mode,
                        uint32_t duration_scan);
extern int bl_main_connect(const uint8_t *ssid, int ssid_len,
                           const uint8_t *psk, int psk_len,
                           const uint8_t *pmk, int pmk_len,
                           const uint8_t *mac, const uint8_t band,
                           const uint16_t freq, const uint32_t flags);
extern int bl_main_disconnect(void);
extern int bl_main_phy_up(void);
extern int bl_main_apm_start(char *ssid, char *password, int channel,
                             uint8_t hidden_ssid, uint16_t bcn_int);
extern int bl_main_apm_stop(void);
extern struct bl_hw wifi_hw;
extern void mpif_clk_init(void);
extern void sysctrl_init(void);
extern void intc_init(void);
extern void ipc_emb_init(void);
extern void bl_init(void);
extern void bl_pm_ops_register(void);
extern void ipc_emb_wait(void);
extern void ke_evt_set(uint32_t events);
extern void ke_evt_schedule(void);
extern void bl_irq_handler(void);
extern void bl_main_event_handle(int param, void *tx_fc_field);
extern void mac_irq(void);
extern void hal_machw_gen_handler(void);
extern void rf_init(uint32_t xtalfreq_hz);
extern void phy_powroffset_set(int8_t power_offset[14]);
extern int coex_pta_force_autocontrol_set(void *arg);
extern void txl_frame_dump(void);
extern void txl_cfm_dump(void);
#ifdef BL808_WIFI_TRACE
extern volatile uint32_t bl808_wifi_trace_rx_all;
#endif
extern uint8_t vif_info_tab[];
extern uint8_t txl_buffer_control_desc[];
extern uint8_t txl_buffer_control_desc_bcmc[];
extern uint8_t txl_buffer_control_24G[];
#ifdef BL808_WIFI_VENDOR_USE_BL808_RF
extern void *wl_cfg_get(uint8_t *rmem);
extern void modem_init_core(uint32_t xtalfreq_hz, uint32_t restore);
#endif
extern uint32_t ke_env[];
int bl_wifi_clock_enable(void);
int bl_wifi_mac_addr_get(uint8_t mac[6]);

__attribute__((weak)) void bl_sleep_schedule(void) {}

extern struct ipc_shared_env_tag ipc_shared_env;
wifi_mgmr_t wifiMgmr;

static int wifi_started;
static int host_poll_enabled;
static int fw_started;
static int sta_enabled;
static int ap_enabled;
static volatile int connect_done = -1;
static volatile int disconnect_done;
static volatile unsigned int scan_done_count;
static volatile unsigned int scan_item_count;
static volatile unsigned int mac_irq_count;
static volatile unsigned int mac_poll_irq_count;
static volatile unsigned int mac_trap_irq_count;
static volatile unsigned int ipc_trap_irq_count;
static volatile unsigned int ipc_poll_irq_count;
static volatile int last_status_code = -1;
static volatile int last_reason_code = -1;

#define VENDOR_SCAN_DIAG_MAX 8
#define VENDOR_SCAN_CACHE_MAX 32
#define VENDOR_VIF_ENTRY_SIZE 1512U
#define VENDOR_VIF_MAC_OFFSET 80U

struct vendor_scan_diag_item {
    uint8_t used;
    uint8_t ssid_len;
    uint8_t ssid[33];
    uint8_t bssid[6];
    uint8_t channel;
    int8_t rssi;
    uint8_t auth;
    uint8_t cipher;
};

static struct vendor_scan_diag_item scan_diag[VENDOR_SCAN_DIAG_MAX];

#ifdef BL808_WIFI_CONNECT_CACHE_HINT
struct vendor_scan_cache_item {
    uint8_t used;
    uint8_t ssid_len;
    uint8_t ssid[33];
    uint8_t bssid[6];
    uint8_t channel;
    int8_t rssi;
    uint8_t auth;
    uint8_t cipher;
};

static struct vendor_scan_cache_item scan_cache[VENDOR_SCAN_CACHE_MAX];
#endif

static void scan_diag_reset(void)
{
    memset(scan_diag, 0, sizeof(scan_diag));
}

static void scan_diag_store(const struct wifi_event_beacon_ind *ind)
{
    unsigned int slot;

    if (!ind || ind->ssid_len < 0 || ind->ssid_len > 32) {
        return;
    }
    slot = scan_item_count % VENDOR_SCAN_DIAG_MAX;
    memset(&scan_diag[slot], 0, sizeof(scan_diag[slot]));
    scan_diag[slot].used = 1;
    scan_diag[slot].ssid_len = (uint8_t)ind->ssid_len;
    if (ind->ssid_len > 0) {
        memcpy(scan_diag[slot].ssid, ind->ssid, (size_t)ind->ssid_len);
    }
    memcpy(scan_diag[slot].bssid, ind->bssid, sizeof(scan_diag[slot].bssid));
    scan_diag[slot].channel = ind->channel;
    scan_diag[slot].rssi = ind->rssi;
    scan_diag[slot].auth = ind->auth;
    scan_diag[slot].cipher = ind->cipher;
}

unsigned int bl808_wifi_vendor_scan_diag_count(void)
{
    return scan_item_count < VENDOR_SCAN_DIAG_MAX ? scan_item_count : VENDOR_SCAN_DIAG_MAX;
}

int bl808_wifi_vendor_scan_diag_get(unsigned int index, uint8_t *ssid_len,
                                    uint8_t *ssid, uint8_t *channel,
                                    int8_t *rssi, uint8_t *auth,
                                    uint8_t *cipher, uint8_t *bssid)
{
    unsigned int start;
    unsigned int slot;

    if (index >= bl808_wifi_vendor_scan_diag_count()) {
        return -1;
    }
    start = scan_item_count > VENDOR_SCAN_DIAG_MAX ?
        (scan_item_count % VENDOR_SCAN_DIAG_MAX) : 0;
    slot = (start + index) % VENDOR_SCAN_DIAG_MAX;
    if (!scan_diag[slot].used) {
        return -1;
    }
    if (ssid_len) {
        *ssid_len = scan_diag[slot].ssid_len;
    }
    if (ssid) {
        memcpy(ssid, scan_diag[slot].ssid, sizeof(scan_diag[slot].ssid));
    }
    if (channel) {
        *channel = scan_diag[slot].channel;
    }
    if (rssi) {
        *rssi = scan_diag[slot].rssi;
    }
    if (auth) {
        *auth = scan_diag[slot].auth;
    }
    if (cipher) {
        *cipher = scan_diag[slot].cipher;
    }
    if (bssid) {
        memcpy(bssid, scan_diag[slot].bssid, sizeof(scan_diag[slot].bssid));
    }
    return 0;
}

struct simple_event_group {
    volatile uint32_t bits;
};

struct simple_queue {
    uint32_t item_size;
    uint32_t depth;
    uint32_t read_idx;
    uint32_t write_idx;
    uint8_t storage[];
};

static uint32_t os_enter_critical(void);
static void os_exit_critical(uint32_t level);
static void vendor_print_char(char c);
static void vendor_print_u32(uint32_t value, unsigned int base);
static void vendor_puts_raw(const char *s);
static void validation_puts_raw(const char *s);

static uint16_t wifi_channel_to_freq(uint8_t channel)
{
    if (channel >= 1 && channel <= 13) {
        return (uint16_t)(2407 + channel * 5);
    }
    if (channel == 14) {
        return 2484;
    }
    return 0;
}

static int mac_is_specific(const uint8_t *mac)
{
    int all_zero = 1;
    int all_ff = 1;

    if (!mac) {
        return 0;
    }
    if (mac[0] & 1) {
        return 0;
    }
    for (int i = 0; i < 6; i++) {
        if (mac[i] != 0) {
            all_zero = 0;
        }
        if (mac[i] != 0xff) {
            all_ff = 0;
        }
    }
    return !all_zero && !all_ff;
}

static uint32_t vendor_pack_mac_low(const uint8_t mac[6])
{
    return (uint32_t)mac[0] | ((uint32_t)mac[1] << 8) |
           ((uint32_t)mac[2] << 16) | ((uint32_t)mac[3] << 24);
}

static uint32_t vendor_pack_mac_high(const uint8_t mac[6])
{
    return (uint32_t)mac[4] | ((uint32_t)mac[5] << 8);
}

static void vendor_print_mac(const uint8_t mac[6])
{
    for (int i = 0; i < 6; i++) {
        if (i) {
            vendor_print_char(':');
        }
        if (mac[i] < 0x10) {
            vendor_print_char('0');
        }
        vendor_print_u32(mac[i], 16);
    }
}

static void vendor_print_ssid(const uint8_t *ssid, int ssid_len)
{
    if (!ssid || ssid_len <= 0) {
        return;
    }
    if (ssid_len > 32) {
        ssid_len = 32;
    }
    for (int i = 0; i < ssid_len; i++) {
        uint8_t ch = ssid[i];
        vendor_print_char((ch >= 0x20 && ch <= 0x7e) ? (char)ch : '.');
    }
}

#ifdef BL808_WIFI_CONNECT_CACHE_HINT
static int ssid_matches(const uint8_t *cached_ssid, uint8_t cached_len,
                        const char *ssid, size_t ssid_len)
{
    if (!ssid || cached_len != ssid_len) {
        return 0;
    }
    return memcmp(cached_ssid, ssid, ssid_len) == 0;
}

static void scan_cache_reset(void)
{
    memset(scan_cache, 0, sizeof(scan_cache));
}

static void scan_cache_store(const struct wifi_event_beacon_ind *ind)
{
    int slot = -1;
    int weakest_slot = -1;
    int weakest_rssi = 128;

    if (!ind || ind->ssid_len <= 0 || ind->ssid_len > 32 ||
        ind->channel == 0 || ind->channel > 14 || !mac_is_specific(ind->bssid)) {
        return;
    }

    for (int i = 0; i < VENDOR_SCAN_CACHE_MAX; i++) {
        if (scan_cache[i].used) {
            if (scan_cache[i].ssid_len == (uint8_t)ind->ssid_len &&
                memcmp(scan_cache[i].ssid, ind->ssid, ind->ssid_len) == 0 &&
                memcmp(scan_cache[i].bssid, ind->bssid, sizeof(scan_cache[i].bssid)) == 0) {
                slot = i;
                break;
            }
            if ((int)scan_cache[i].rssi < weakest_rssi) {
                weakest_rssi = scan_cache[i].rssi;
                weakest_slot = i;
            }
        } else if (slot < 0) {
            slot = i;
        }
    }

    if (slot < 0) {
        slot = weakest_slot;
    }
    if (slot < 0) {
        return;
    }
    if (scan_cache[slot].used && ind->rssi < scan_cache[slot].rssi &&
        memcmp(scan_cache[slot].bssid, ind->bssid, sizeof(scan_cache[slot].bssid)) == 0) {
        return;
    }

    memset(&scan_cache[slot], 0, sizeof(scan_cache[slot]));
    scan_cache[slot].used = 1;
    scan_cache[slot].ssid_len = (uint8_t)ind->ssid_len;
    memcpy(scan_cache[slot].ssid, ind->ssid, ind->ssid_len);
    memcpy(scan_cache[slot].bssid, ind->bssid, sizeof(scan_cache[slot].bssid));
    scan_cache[slot].channel = ind->channel;
    scan_cache[slot].rssi = ind->rssi;
    scan_cache[slot].auth = ind->auth;
    scan_cache[slot].cipher = ind->cipher;
}

static int scan_cache_find(const char *ssid, size_t ssid_len, const uint8_t *requested_mac,
                           uint8_t bssid_out[6], uint8_t *channel_out, int8_t *rssi_out)
{
    int best_slot = -1;
    int best_rssi = -129;
    int require_mac = mac_is_specific(requested_mac);

    for (int i = 0; i < VENDOR_SCAN_CACHE_MAX; i++) {
        if (!scan_cache[i].used) {
            continue;
        }
        if (require_mac &&
            memcmp(scan_cache[i].bssid, requested_mac, sizeof(scan_cache[i].bssid)) != 0) {
            continue;
        }
        if (!ssid_matches(scan_cache[i].ssid, scan_cache[i].ssid_len, ssid, ssid_len)) {
            continue;
        }
        if ((int)scan_cache[i].rssi > best_rssi) {
            best_rssi = scan_cache[i].rssi;
            best_slot = i;
        }
    }

    if (best_slot < 0) {
        return 0;
    }
    memcpy(bssid_out, scan_cache[best_slot].bssid, sizeof(scan_cache[best_slot].bssid));
    *channel_out = scan_cache[best_slot].channel;
    *rssi_out = scan_cache[best_slot].rssi;
    return 1;
}
#endif

#define BL808_IRQ_BASE 16UL
#define BL808_IRQ_WIFI (BL808_IRQ_BASE + 54UL)
#define BL808_IRQ_WIFI_IPC_PUBLIC (BL808_IRQ_BASE + 63UL)

static void raw_delay(unsigned int loops)
{
    volatile unsigned int i;
    for (i = 0; i < loops; i++) {
        __asm__ volatile("nop");
    }
}

static uint64_t read_mtime_us(void)
{
    volatile uint32_t *mtime = (volatile uint32_t *)0xE000BFF8UL;
    uint32_t hi1;
    uint32_t lo;
    uint32_t hi2;

    do {
        hi1 = mtime[1];
        lo = mtime[0];
        hi2 = mtime[1];
    } while (hi1 != hi2);

    return ((uint64_t)hi1 << 32) | lo;
}

#ifdef BL808_WIFI_VENDOR_USE_BL808_RF
static uint64_t read_cycle64(void)
{
    uint32_t hi1;
    uint32_t lo;
    uint32_t hi2;

    do {
        __asm__ volatile("csrr %0, mcycleh" : "=r"(hi1));
        __asm__ volatile("csrr %0, mcycle" : "=r"(lo));
        __asm__ volatile("csrr %0, mcycleh" : "=r"(hi2));
    } while (hi1 != hi2);

    return ((uint64_t)hi1 << 32) | lo;
}

static void delay_cycle_us(uint32_t us)
{
    const uint32_t cycles_per_us = 160U;
    uint64_t deadline = read_cycle64() + ((uint64_t)us * cycles_per_us);

    while ((int64_t)(read_cycle64() - deadline) < 0) {
        __asm__ volatile("nop");
    }
}
#endif

static void delay_mtime_us(uint32_t us)
{
    uint64_t now = read_mtime_us();
    uint64_t last = now;
    uint64_t deadline = now + us;
    unsigned int stale_reads = 0;

    while ((int64_t)(now - deadline) < 0) {
        raw_delay(32);
        now = read_mtime_us();
        if (now == last) {
            stale_reads++;
            if (stale_reads > 1024) {
                raw_delay((us * 96U) + 2048U);
                return;
            }
        } else {
            last = now;
            stale_reads = 0;
        }
    }
}

void arch_delay_us(uint32_t us)
{
#ifdef BL808_WIFI_VENDOR_USE_BL808_RF
    delay_cycle_us(us);
#else
    delay_mtime_us(us);
#endif
}

void udelay(uint32_t us)
{
    arch_delay_us(us);
}

__attribute__((weak)) void wait_us(uint32_t us)
{
    arch_delay_us(us);
}

void __wrap_wait_us(uint32_t us)
{
    arch_delay_us(us);
}

#ifdef BL808_WIFI_VENDOR_USE_BL808_RF
__attribute__((weak)) int abs(int value)
{
    return value < 0 ? -value : value;
}

__attribute__((weak)) double log(double x)
{
    union {
        double d;
        uint64_t u;
    } v;
    const double ln2 = 0.69314718055994530942;
    double y;
    double y2;
    double term;
    double sum;
    int exp;

    if (x <= 0.0) {
        return -1.0e308;
    }

    v.d = x;
    exp = (int)((v.u >> 52) & 0x7ffu) - 1023;
    v.u = (v.u & 0x000fffffffffffffull) | (uint64_t)0x3ff0000000000000ull;

    y = (v.d - 1.0) / (v.d + 1.0);
    y2 = y * y;
    term = y;
    sum = term;
    for (int n = 3; n <= 21; n += 2) {
        term *= y2;
        sum += term / (double)n;
    }
    return 2.0 * sum + (double)exp * ln2;
}
#endif

static uint32_t reg_read32(uint32_t addr)
{
    return *(volatile uint32_t *)addr;
}

static void reg_write32(uint32_t addr, uint32_t value)
{
    *(volatile uint32_t *)addr = value;
}

static void reg_update32(uint32_t addr, uint32_t mask, uint32_t value)
{
    uint32_t current = reg_read32(addr);
    reg_write32(addr, (current & ~mask) | (value & mask));
}

static void bl808_wifi_vendor_sw_reset_cfg0(uint32_t bit)
{
    const uint32_t reg = 0x20000000UL + 0x540UL;
    const uint32_t mask = 1UL << bit;

    reg_write32(reg, reg_read32(reg) & ~mask);
    (void)reg_read32(reg);
    reg_write32(reg, reg_read32(reg) | mask);
    (void)reg_read32(reg);
    reg_write32(reg, reg_read32(reg) & ~mask);
    (void)reg_read32(reg);
}

static void bl808_wifi_vendor_enable_wireless_clocks(void)
{
    reg_write32(0x20000000UL + 0x580UL,
                reg_read32(0x20000000UL + 0x580UL) |
                ((1UL << 5) | (1UL << 6) | (1UL << 7)));
    reg_write32(0x20000000UL + 0x584UL,
                reg_read32(0x20000000UL + 0x584UL) | (1UL << 1));
    reg_write32(0x20000000UL + 0x588UL,
                reg_read32(0x20000000UL + 0x588UL) |
                ((1UL << 4) | (1UL << 8) | (1UL << 10)));
    reg_update32(0x20000000UL + 0x3B0UL, 0x0FUL, 1UL);
}

static void bl808_wifi_vendor_configure_dig_clock(void)
{
    const uint32_t reg = 0x20000000UL + 0x250UL;
    uint32_t v = reg_read32(reg);
    uint32_t dig32_en = v & (1UL << 12);

    v &= ~((1UL << 24) | (1UL << 12));
    reg_write32(reg, v);

    v = reg_read32(reg);
    v = (v & ~(3UL << 28)) | (1UL << 28);
    reg_write32(reg, v);

    v = reg_read32(reg);
    v &= ~(0x7FUL << 16);
    v |= (0x4EUL << 16) | (1UL << 25) | (1UL << 24) | dig32_en;
    reg_write32(reg, v);
}

static void bl808_wifi_vendor_power_on_xtal_wifipll(void)
{
    const uint32_t glb = 0x20000000UL;
    const uint32_t aon = 0x2000F000UL;
    const uint32_t hbn = 0x2000F000UL;
    const uint32_t mm_glb = 0x30007000UL;
    const uint32_t hbn_rsv3 = hbn + 0x10CUL;

    reg_write32(aon + 0x880UL,
                reg_read32(aon + 0x880UL) |
                ((1UL << 0) | (1UL << 1) | (1UL << 2) |
                 (1UL << 4) | (1UL << 5)));
    arch_delay_us(120);

    reg_write32(hbn_rsv3, (reg_read32(hbn_rsv3) & 0xFFFF0000UL) | 0x5804UL);

    if ((reg_read32(glb + 0x810UL) & (1UL << 10)) != 0) {
        reg_write32(glb + 0x824UL, reg_read32(glb + 0x824UL) | (1UL << 12));
        reg_write32(glb + 0x830UL,
                    reg_read32(glb + 0x830UL) |
                    ((1UL << 31) | (1UL << 1) | (1UL << 2) |
                     (1UL << 3) | (1UL << 4) | (1UL << 5)));
        reg_write32(glb + 0x090UL, reg_read32(glb + 0x090UL) | (1UL << 0));
        reg_write32(mm_glb + 0x000UL,
                    reg_read32(mm_glb + 0x000UL) | (1UL << 0));
        return;
    }

    reg_update32(glb + 0x810UL, (1UL << 10) | (1UL << 9), 0);
    reg_update32(glb + 0x814UL, (0x0FUL << 8) | (0x03UL << 16),
                 (2UL << 8) | (1UL << 16));
    reg_update32(glb + 0x818UL,
                 (1UL << 8) | (0x03UL << 6) | (0x03UL << 4),
                 2UL << 4);
    reg_update32(glb + 0x81CUL,
                 (1UL << 0) | (1UL << 8) | (0x03UL << 12) |
                 (0x03UL << 14) | (0x07UL << 16),
                 (1UL << 8) | (2UL << 12) | (1UL << 14) |
                 (3UL << 16));
    reg_update32(glb + 0x820UL, 0x03UL << 0, 1UL << 0);
    reg_update32(glb + 0x824UL, 0x07UL << 0, 5UL << 0);
    reg_update32(glb + 0x828UL,
                 (0x03FFFFFFUL << 0) | (1UL << 28) | (1UL << 31),
                 0x01800000UL | (1UL << 28) | (1UL << 31));

    reg_write32(glb + 0x810UL, reg_read32(glb + 0x810UL) | (1UL << 9));
    arch_delay_us(3);
    reg_write32(glb + 0x810UL, reg_read32(glb + 0x810UL) | (1UL << 10));
    arch_delay_us(3);

    reg_write32(glb + 0x810UL, reg_read32(glb + 0x810UL) | (1UL << 0));
    arch_delay_us(2);
    reg_write32(glb + 0x810UL, reg_read32(glb + 0x810UL) & ~(1UL << 0));
    arch_delay_us(2);
    reg_write32(glb + 0x810UL, reg_read32(glb + 0x810UL) | (1UL << 0));

    reg_write32(glb + 0x810UL, reg_read32(glb + 0x810UL) | (1UL << 2));
    arch_delay_us(2);
    reg_write32(glb + 0x810UL, reg_read32(glb + 0x810UL) & ~(1UL << 2));
    arch_delay_us(2);
    reg_write32(glb + 0x810UL, reg_read32(glb + 0x810UL) | (1UL << 2));

    reg_write32(glb + 0x824UL, reg_read32(glb + 0x824UL) | (1UL << 12));
    reg_write32(glb + 0x830UL,
                reg_read32(glb + 0x830UL) |
                ((1UL << 31) | (1UL << 1) | (1UL << 2) |
                 (1UL << 3) | (1UL << 4) | (1UL << 5)));
    arch_delay_us(75);

    reg_write32(glb + 0x090UL, reg_read32(glb + 0x090UL) | (1UL << 0));
    reg_write32(mm_glb + 0x000UL, reg_read32(mm_glb + 0x000UL) | (1UL << 0));
}

static void bl808_wifi_vendor_prepare_wireless_domain(void)
{
    static int prepared;

    if (prepared) {
        bl808_wifi_vendor_enable_wireless_clocks();
        return;
    }

    reg_update32(0x20000000UL + 0x60CUL, 0xFFUL, 0x00UL);
    bl808_wifi_vendor_power_on_xtal_wifipll();
    bl808_wifi_vendor_configure_dig_clock();
    bl808_wifi_vendor_enable_wireless_clocks();
    bl808_wifi_vendor_sw_reset_cfg0(4);
    bl808_wifi_vendor_configure_dig_clock();
    bl808_wifi_vendor_enable_wireless_clocks();
    prepared = 1;
}

static void bl808_wifi_vendor_dump_mac_regs(const char *tag)
{
#ifdef BL808_WIFI_VERBOSE_CONNECT
    vendor_puts_raw("[WIFI] macregs ");
    vendor_puts_raw(tag);
    vendor_puts_raw(" bcn=0x");
    vendor_print_u32(reg_read32(0x24B00400UL), 16);
    vendor_puts_raw(" pti=0x");
    vendor_print_u32(reg_read32(0x24B00404UL), 16);
    vendor_puts_raw(" coex=0x");
    vendor_print_u32(reg_read32(0x24920004UL), 16);
    vendor_puts_raw(" pta=0x");
    vendor_print_u32(reg_read32(0x24920404UL), 16);
    vendor_puts_raw(" pta2=0x");
    vendor_print_u32(reg_read32(0x24920428UL), 16);
    vendor_puts_raw(" own0=0x");
    vendor_print_u32(reg_read32(0x24B00010UL), 16);
    vendor_puts_raw(" own1=0x");
    vendor_print_u32(reg_read32(0x24B00014UL), 16);
    vendor_puts_raw(" ownmask=0x");
    vendor_print_u32(reg_read32(0x24B0001CUL), 16);
    vendor_puts_raw("\r\n");
#else
    (void)tag;
#endif
}

static void bl808_wifi_vendor_dump_tx_power_regs(const char *tag)
{
#ifdef BL808_WIFI_VERBOSE_CONNECT
    vendor_puts_raw("[WIFI] txpwr ");
    vendor_puts_raw(tag);
    vendor_puts_raw(" max=0x");
    vendor_print_u32(reg_read32(0x24B0009CUL), 16);
    vendor_puts_raw(" ctl=0x");
    vendor_print_u32(reg_read32(0x24B000A0UL), 16);
    vendor_puts_raw(" basic=0x");
    vendor_print_u32(reg_read32(0x24B000DCUL), 16);
    vendor_puts_raw(" cca=0x");
    vendor_print_u32(reg_read32(0x24B00114UL), 16);
    vendor_puts_raw("\r\n");
#else
    (void)tag;
#endif
}

static void bl808_wifi_vendor_force_response_tx_power(const char *tag)
{
#ifdef BL808_WIFI_FORCE_RESP_TX_POWER
    static uint32_t last_reg;
    static uint32_t log_count;
    uint32_t old_reg = reg_read32(0x24B000A0UL);
#ifdef BL808_WIFI_FORCE_RESP_TX_POWER_ALL
    uint32_t power = (uint32_t)BL808_WIFI_FORCE_RESP_TX_POWER & 0xFFUL;
    uint32_t new_reg = power | (power << 8) | (power << 16) | (power << 24);
#else
    uint32_t new_reg = (old_reg & 0xFFFF0000UL) |
                       ((uint32_t)BL808_WIFI_FORCE_RESP_TX_POWER & 0xFFUL) |
                       (((uint32_t)BL808_WIFI_FORCE_RESP_TX_POWER & 0xFFUL) << 8);
#endif

    if (new_reg != old_reg) {
        reg_write32(0x24B000A0UL, new_reg);
    }

    {
        uint32_t power = (uint32_t)BL808_WIFI_FORCE_RESP_TX_POWER & 0xFFUL;
        for (uint32_t i = 0; i < 5; i++) {
            uint8_t *desc = txl_buffer_control_desc + (i * 60UL);
            *(uint32_t *)(desc + 36) = power;
            *(uint32_t *)(desc + 40) = power;
            *(uint32_t *)(desc + 44) = power;
            *(uint32_t *)(desc + 48) = power;
        }
        for (uint32_t i = 0; i < 2; i++) {
            uint8_t *desc = txl_buffer_control_desc_bcmc + (i * 60UL);
            *(uint32_t *)(desc + 36) = power;
        }
        *(uint32_t *)(txl_buffer_control_24G + 36) = power;
        *(uint32_t *)(txl_buffer_control_24G + 40) = power;
        *(uint32_t *)(txl_buffer_control_24G + 44) = power;
        *(uint32_t *)(txl_buffer_control_24G + 48) = power;
    }

    if ((old_reg != last_reg || new_reg != old_reg) && log_count < 8) {
        vendor_puts_raw("[WIFI] force-resp-txpwr ");
        vendor_puts_raw(tag);
        vendor_puts_raw(" old=0x");
        vendor_print_u32(old_reg, 16);
        vendor_puts_raw(" new=0x");
        vendor_print_u32(reg_read32(0x24B000A0UL), 16);
        vendor_puts_raw(" ctl0=0x");
        vendor_print_u32(*(uint32_t *)(txl_buffer_control_desc + 36), 16);
        vendor_puts_raw(" ctl24=0x");
        vendor_print_u32(*(uint32_t *)(txl_buffer_control_24G + 36), 16);
        vendor_puts_raw("\r\n");
        last_reg = old_reg;
        log_count++;
    }
#else
    (void)tag;
#endif
}

static void bl808_wifi_vendor_force_ack_mode(const char *tag)
{
#ifdef BL808_WIFI_FORCE_ACK_MODE
    bl808_wifi_vendor_dump_mac_regs(tag);
    reg_write32(0x24920428UL, 0x00000000UL);
    reg_write32(0x24920404UL, 0x50000013UL);
    reg_write32(0x24B00400UL, 0x00000F48UL);
    reg_write32(0x24B00404UL, 0xFFFFFFFFUL);
    reg_write32(0x24B00400UL, 0x00000F49UL);
    bl808_wifi_vendor_dump_mac_regs("force-ack");
#else
    (void)tag;
#endif
}

static void bl808_wifi_vendor_force_pta_wlan(const char *tag)
{
#ifdef BL808_WIFI_FORCE_PTA_WLAN
    bl808_wifi_vendor_dump_mac_regs(tag);
    (void)coex_pta_force_autocontrol_set((void *)1);
    bl808_wifi_vendor_dump_mac_regs("force-pta-wlan");
#else
    (void)tag;
#endif
}

static void bl808_wifi_vendor_drive_rf_status(void)
{
    uint32_t rf_ctrl = reg_read32(0x24900084UL);

    if ((reg_read32(0x24B00120UL) & 0x00080000UL) != 0) {
        rf_ctrl |= 0x01UL;
    } else {
        rf_ctrl &= ~0x01UL;
    }
    reg_write32(0x24900084UL, rf_ctrl);
}

static const uint8_t *bl808_wifi_vendor_vif_mac(uint8_t vif_idx)
{
    if (vif_idx >= CFG_VIRT_DEV_MAX) {
        return NULL;
    }
    return &vif_info_tab[(uint32_t)vif_idx * VENDOR_VIF_ENTRY_SIZE +
                         VENDOR_VIF_MAC_OFFSET];
}

static void bl808_wifi_vendor_force_own_mac(const uint8_t *mac,
                                            const char *tag)
{
#ifdef BL808_WIFI_FORCE_VIF_OWN_MAC
    uint32_t lo;
    uint32_t hi;

    if (!mac_is_specific(mac)) {
        return;
    }

    lo = vendor_pack_mac_low(mac);
    hi = vendor_pack_mac_high(mac);
#ifdef BL808_WIFI_VERBOSE_CONNECT
    vendor_puts_raw("[WIFI] ownmac ");
    vendor_puts_raw(tag);
    vendor_puts_raw(" vif=");
    vendor_print_mac(mac);
    vendor_puts_raw(" old=0x");
    vendor_print_u32(reg_read32(0x24B00010UL), 16);
    vendor_puts_raw("/0x");
    vendor_print_u32(reg_read32(0x24B00014UL), 16);
    vendor_puts_raw("/0x");
    vendor_print_u32(reg_read32(0x24B0001CUL), 16);
#endif
    reg_write32(0x24B00010UL, lo);
    reg_write32(0x24B00014UL, hi);
    reg_write32(0x24B0001CUL, 0x100UL);
#ifdef BL808_WIFI_VERBOSE_CONNECT
    vendor_puts_raw(" new=0x");
    vendor_print_u32(reg_read32(0x24B00010UL), 16);
    vendor_puts_raw("/0x");
    vendor_print_u32(reg_read32(0x24B00014UL), 16);
    vendor_puts_raw("/0x");
    vendor_print_u32(reg_read32(0x24B0001CUL), 16);
    vendor_puts_raw("\r\n");
#endif
#else
    (void)mac;
    (void)tag;
#endif
}

static uint32_t bl808_wifi_vendor_rescale_field(uint32_t raw, uint32_t shift,
                                                uint32_t width,
                                                uint32_t old_clk,
                                                uint32_t new_clk)
{
    uint32_t mask = (1UL << width) - 1UL;
    uint32_t field = (raw >> shift) & mask;
    uint32_t scaled = old_clk ? ((field * new_clk) / old_clk) : field;

    if (scaled > mask) {
        scaled = mask;
    }
    return (raw & ~(mask << shift)) | ((scaled & mask) << shift);
}

static void bl808_wifi_vendor_force_mac_timing_80mhz(const char *tag)
{
#ifdef BL808_WIFI_FORCE_MAC_TIMING_80MHZ
    const uint32_t old_clk = reg_read32(0x24B000E4UL) & 0xffUL;
    const uint32_t new_clk = 80UL;
    uint32_t r;

    if (old_clk == 0UL || old_clk == new_clk) {
        return;
    }

#ifdef BL808_WIFI_VERBOSE_CONNECT
    vendor_puts_raw("[WIFI] timing80 ");
    vendor_puts_raw(tag);
    vendor_puts_raw(" old=");
    vendor_print_u32(old_clk, 10);
    vendor_puts_raw(" e4=0x");
    vendor_print_u32(reg_read32(0x24B000E4UL), 16);
    vendor_puts_raw(" e8=0x");
    vendor_print_u32(reg_read32(0x24B000E8UL), 16);
    vendor_puts_raw(" ec=0x");
    vendor_print_u32(reg_read32(0x24B000ECUL), 16);
    vendor_puts_raw(" f0=0x");
    vendor_print_u32(reg_read32(0x24B000F0UL), 16);
    vendor_puts_raw(" f4=0x");
    vendor_print_u32(reg_read32(0x24B000F4UL), 16);
    vendor_puts_raw(" f8=0x");
    vendor_print_u32(reg_read32(0x24B000F8UL), 16);
    vendor_puts_raw(" 104=0x");
    vendor_print_u32(reg_read32(0x24B00104UL), 16);
    vendor_puts_raw("\r\n");
#endif

    r = reg_read32(0x24B000E4UL);
    r = (r & 0xffffff00UL) | new_clk;
    r = bl808_wifi_vendor_rescale_field(r, 8UL, 10UL, old_clk, new_clk);
    r = (r & 0xf003ffffUL) | 0x02200000UL;
    reg_write32(0x24B000E4UL, r);

    r = reg_read32(0x24B000E8UL);
    r = bl808_wifi_vendor_rescale_field(r, 8UL, 16UL, old_clk, new_clk);
    reg_write32(0x24B000E8UL, r);

    r = reg_read32(0x24B000ECUL);
    r = (r & 0xc00fffffUL) | 0x02700000UL;
    r = bl808_wifi_vendor_rescale_field(r, 10UL, 10UL, old_clk, new_clk);
    r = (r & 0xfffffc00UL) | 180UL;
    reg_write32(0x24B000ECUL, r);

    r = reg_read32(0x24B000F0UL);
    r = (r & ~0x03UL) | 0x01UL;
    reg_write32(0x24B000F0UL, r);

    r = reg_read32(0x24B000F4UL);
    r = bl808_wifi_vendor_rescale_field(r, 8UL, 16UL, old_clk, new_clk);
    reg_write32(0x24B000F4UL, r);

    r = reg_read32(0x24B000F8UL);
    r = bl808_wifi_vendor_rescale_field(r, 8UL, 16UL, old_clk, new_clk);
    reg_write32(0x24B000F8UL, r);

    r = reg_read32(0x24B00104UL);
    r = bl808_wifi_vendor_rescale_field(r, 20UL, 10UL, old_clk, new_clk);
    r = bl808_wifi_vendor_rescale_field(r, 10UL, 10UL, old_clk, new_clk);
    r = bl808_wifi_vendor_rescale_field(r, 0UL, 10UL, old_clk, new_clk);
    reg_write32(0x24B00104UL, r);

#ifdef BL808_WIFI_VERBOSE_CONNECT
    vendor_puts_raw("[WIFI] timing80 applied e4=0x");
    vendor_print_u32(reg_read32(0x24B000E4UL), 16);
    vendor_puts_raw(" e8=0x");
    vendor_print_u32(reg_read32(0x24B000E8UL), 16);
    vendor_puts_raw(" ec=0x");
    vendor_print_u32(reg_read32(0x24B000ECUL), 16);
    vendor_puts_raw(" f0=0x");
    vendor_print_u32(reg_read32(0x24B000F0UL), 16);
    vendor_puts_raw(" f4=0x");
    vendor_print_u32(reg_read32(0x24B000F4UL), 16);
    vendor_puts_raw(" f8=0x");
    vendor_print_u32(reg_read32(0x24B000F8UL), 16);
    vendor_puts_raw(" 104=0x");
    vendor_print_u32(reg_read32(0x24B00104UL), 16);
    vendor_puts_raw("\r\n");
#endif
#else
    (void)tag;
#endif
}

static void bl808_wifi_vendor_poll_emb_events(void)
{
    const uint32_t ipc_emb2app_status = 0x24800104UL;
    const uint32_t ipc_a2e_msg = 1UL << 1;
    const uint32_t ke_evt_ipc_emb_msg = 0x10000000UL;

    if (reg_read32(ipc_emb2app_status) & ipc_a2e_msg) {
        ke_evt_set(ke_evt_ipc_emb_msg);
    }
}

static void bl808_wifi_vendor_clear_emb_ipc(void)
{
    const uint32_t ipc_app2emb_ack = 0x2480010cUL;

    reg_write32(ipc_app2emb_ack, 0xffffffffUL);
}

static void bl808_wifi_vendor_clear_host_ipc(void)
{
    const uint32_t ipc_emb2app_ack = 0x24800008UL;

    reg_write32(ipc_emb2app_ack, 0xffffffffUL);
}

static uint32_t bl808_wifi_vendor_host_ipc_status(void)
{
    const uint32_t ipc_emb2app_rawstatus = 0x24800004UL;

    return reg_read32(ipc_emb2app_rawstatus);
}

static void bl808_wifi_vendor_poll_mac_irq(void)
{
    const uint32_t mac_irq_status0 = 0x24910000UL;
    const uint32_t mac_irq_status1 = 0x24910004UL;
    const uint32_t machw_irq_raw = 0x24B0806CUL;
    const uint32_t machw_irq_unmask = 0x24B08074UL;
    unsigned int guard = 32;

    while (guard--) {
        const uint32_t platform_pending =
            reg_read32(mac_irq_status0) | reg_read32(mac_irq_status1);
        const uint32_t machw_pending =
            reg_read32(machw_irq_raw) & reg_read32(machw_irq_unmask);
        if ((platform_pending == 0) && (machw_pending == 0)) {
            break;
        }
        mac_irq_count++;
        mac_poll_irq_count++;
        if (platform_pending != 0) {
            mac_irq();
        } else {
            hal_machw_gen_handler();
        }
    }
}

static void bl808_wifi_vendor_mac_irq_trampoline(void)
{
    mac_irq_count++;
    mac_trap_irq_count++;
    mac_irq();
}

static void bl808_wifi_vendor_ipc_irq_trampoline(void)
{
    ipc_trap_irq_count++;
    bl_irq_handler();
}

static void bl808_wifi_vendor_apply_high_power_profile(void)
{
    int8_t channel_offset[14] = {0};
#ifdef BL808_WIFI_VENDOR_OFFICIAL_POWER_PROFILE
    int8_t pwr_11b[4] = {0x14, 0x14, 0x14, 0x12};
    int8_t pwr_11g[8] = {0x12, 0x12, 0x12, 0x12, 0x12, 0x12, 0x0e, 0x0e};
    int8_t pwr_11n[8] = {0x12, 0x12, 0x12, 0x12, 0x12, 0x10, 0x0e, 0x0e};
#else
    int8_t pwr_11b[4] = {0x1c, 0x1c, 0x1c, 0x1c};
    int8_t pwr_11g[8] = {0x1c, 0x1c, 0x1c, 0x1c, 0x1c, 0x1c, 0x1c, 0x1c};
    int8_t pwr_11n[8] = {0x1c, 0x1c, 0x1c, 0x1c, 0x1c, 0x1c, 0x1c, 0x1c};
#endif

    phy_powroffset_set(channel_offset);
    bl_tpc_update_power_rate_11b(pwr_11b);
    bl_tpc_update_power_rate_11g(pwr_11g);
    bl_tpc_update_power_rate_11n(pwr_11n);
#ifdef BL808_WIFI_VENDOR_OFFICIAL_POWER_PROFILE
    vendor_puts_raw("[WIFI] RF official power profile applied\r\n");
#else
    vendor_puts_raw("[WIFI] RF high-power profile applied\r\n");
#endif
    bl808_wifi_vendor_dump_tx_power_regs("profile");
}

#if defined(BL808_WIFI_NIM_FW) || defined(BL808_WIFI_VENDOR_USE_BL808_RF)
static void bl808_wifi_vendor_nim_fw_trace(const char *step)
{
#ifdef BL808_WIFI_NIM_FW
    validation_puts_raw("[WIFI-NIMFW] ");
    validation_puts_raw(step);
    validation_puts_raw("\r\n");
    vendor_puts_raw("[WIFI-NIMFW] ");
    vendor_puts_raw(step);
    vendor_puts_raw("\r\n");
#else
    validation_puts_raw("[WIFI-RF] ");
    validation_puts_raw(step);
    validation_puts_raw("\r\n");
    vendor_puts_raw("[WIFI-RF] ");
    vendor_puts_raw(step);
    vendor_puts_raw("\r\n");
#endif
}
#else
static void bl808_wifi_vendor_nim_fw_trace(const char *step)
{
    (void)step;
}
#endif

#ifdef BL808_WIFI_VENDOR_USE_BL808_RF
static uint8_t wifi_bl808_wl_rmem[544] __attribute__((aligned(4)));

extern uint32_t crm_get_mac_freq(void);

uint32_t phy_get_mac_freq(void)
{
    return crm_get_mac_freq();
}

void mpif_clk_init(void)
{
}

void phy_powroffset_set(int8_t power_offset[14])
{
    (void)power_offset;
}

void trpc_power_get(void *power_table)
{
    (void)power_table;
}

static void bl808_wifi_vendor_configure_wl(uint32_t xtalfreq_hz)
{
    uint8_t *cfg = (uint8_t *)wl_cfg_get(wifi_bl808_wl_rmem);
    if (!cfg) {
        return;
    }

    *(uint32_t *)(cfg + 0) = 0;                 /* status */
    cfg[4] = 1;                                 /* WL_API_MODE_WLAN */
    cfg[5] = 0;                                 /* en_param_load */
    cfg[6] = 0;                                 /* en_full_cal */
    cfg[7] = 0;
    *(uint32_t *)(cfg + 8) = xtalfreq_hz;       /* param.xtalfreq_hz */
    *(void **)(cfg + 200) = 0;                  /* param_load */
    *(void **)(cfg + 204) = 0;                  /* capcode_set */
    *(void **)(cfg + 208) = 0;                  /* capcode_get */
}
#endif

static void bl808_wifi_vendor_fw_start(void)
{
    uint32_t irq_state;
    const uint32_t intc_pend = 0x40000000UL + 0x10UL;
    const uint32_t bcn_status = 0x24B00400UL;
    const uint32_t coex_ctrl = 0x24920004UL;

    if (fw_started) {
        return;
    }

    bl_wifi_clock_enable();

    irq_state = os_enter_critical();
    reg_write32(intc_pend, reg_read32(intc_pend) | 0x10UL);
    arch_delay_us(100);
    reg_write32(intc_pend, reg_read32(intc_pend) & ~0x10UL);
    arch_delay_us(100);
    os_exit_critical(irq_state);

    bl808_wifi_vendor_nim_fw_trace("wifi_hosal_rf_turn_on begin");
    (void)wifi_hosal_rf_turn_on(NULL);
    bl808_wifi_vendor_nim_fw_trace("wifi_hosal_rf_turn_on done");
#ifdef BL808_WIFI_VENDOR_USE_BL808_RF
    bl808_wifi_vendor_nim_fw_trace("configure_wl begin");
    bl808_wifi_vendor_configure_wl(40000000UL);
    bl808_wifi_vendor_nim_fw_trace("configure_wl done");
#endif
    bl808_wifi_vendor_nim_fw_trace("rf_init begin");
#ifdef BL808_WIFI_VENDOR_USE_BL808_RF
    modem_init_core(40000000UL, 1);
#else
    rf_init(40000000UL);
#endif
    bl808_wifi_vendor_nim_fw_trace("rf_init done");
    bl808_wifi_vendor_nim_fw_trace("high_power_profile begin");
    bl808_wifi_vendor_apply_high_power_profile();
    bl808_wifi_vendor_nim_fw_trace("high_power_profile done");
    bl808_wifi_vendor_nim_fw_trace("mpif_clk_init begin");
    mpif_clk_init();
    bl808_wifi_vendor_nim_fw_trace("mpif_clk_init done");
    bl808_wifi_vendor_nim_fw_trace("sysctrl_init begin");
    sysctrl_init();
    bl808_wifi_vendor_nim_fw_trace("sysctrl_init done");
    bl808_wifi_vendor_nim_fw_trace("intc_init begin");
    intc_init();
    bl808_wifi_vendor_nim_fw_trace("intc_init done");
    bl808_wifi_vendor_nim_fw_trace("ipc_emb_init begin");
    ipc_emb_init();
    bl808_wifi_vendor_nim_fw_trace("ipc_emb_init done");
    bl808_wifi_vendor_clear_emb_ipc();
    bl808_wifi_vendor_clear_host_ipc();
    bl808_wifi_vendor_nim_fw_trace("bl_init begin");
    bl_init();
    bl808_wifi_vendor_nim_fw_trace("bl_init done");
    bl808_wifi_vendor_dump_tx_power_regs("post-bl-init");
    bl808_wifi_vendor_force_response_tx_power("post-bl-init");
    bl808_wifi_vendor_nim_fw_trace("bl_pm_ops_register begin");
    bl_pm_ops_register();
    bl808_wifi_vendor_nim_fw_trace("bl_pm_ops_register done");

    reg_write32(bcn_status + 4, 0x0024F037UL);
    reg_write32(bcn_status, reg_read32(bcn_status) | 0x01UL);
    reg_write32(bcn_status, reg_read32(bcn_status) & ~0x01UL);
    reg_write32(bcn_status, 0x68UL);
    reg_write32(bcn_status, reg_read32(bcn_status) | 0x01UL);
    reg_write32(bcn_status, reg_read32(bcn_status) & ~0x20UL);
#ifdef BL808_WIFI_KEEP_BCN_BIT5
    reg_write32(bcn_status, reg_read32(bcn_status) | 0x20UL);
#endif
    reg_write32(coex_ctrl, 0x5010001FUL);
    bl808_wifi_vendor_dump_mac_regs("fw-start");
    bl808_wifi_vendor_force_pta_wlan("fw-start");
    bl808_wifi_vendor_force_mac_timing_80mhz("fw-start");
    bl808_wifi_vendor_force_ack_mode("fw-start");
    bl808_wifi_vendor_dump_tx_power_regs("fw-start");
    bl808_wifi_vendor_force_response_tx_power("fw-start");

    fw_started = 1;
}

static void vendor_poll_once(void)
{
    if (fw_started) {
        bl808_wifi_vendor_poll_emb_events();
        bl808_wifi_vendor_poll_mac_irq();
        bl808_wifi_vendor_drive_rf_status();
        bl808_wifi_vendor_force_response_tx_power("poll");
        if (bl808_wifi_vendor_host_ipc_status() != 0) {
            ipc_poll_irq_count++;
            bl_irq_handler();
            bl808_wifi_vendor_force_response_tx_power("host-irq");
        }
        bl_sleep_schedule();
        if (ke_env[0] == 0) {
            ipc_emb_wait();
        }
        ke_evt_schedule();
        bl808_wifi_vendor_force_response_tx_power("sched");
    }
    if (host_poll_enabled && wifi_hw.ipc_env) {
        bl_main_event_handle(0, NULL);
    }
}

static void vendor_poll_for(unsigned int iterations)
{
    while (iterations--) {
        vendor_poll_once();
        delay_mtime_us(100);
    }
}

void bl808_wifi_vendor_poll(unsigned int iterations)
{
    vendor_poll_for(iterations ? iterations : 1);
}

int bl808_wifi_vendor_connected(void)
{
    return connect_done == 0;
}

int bl808_wifi_vendor_connect_done(void)
{
    return connect_done >= 0;
}

int bl808_wifi_vendor_last_status(void)
{
    return last_status_code;
}

int bl808_wifi_vendor_last_reason(void)
{
    return last_reason_code;
}

unsigned int bl808_wifi_vendor_scan_count(void)
{
    return scan_item_count;
}

unsigned int bl808_wifi_vendor_scan_done_count(void)
{
    return scan_done_count;
}

unsigned int bl808_wifi_vendor_mac_irq_count(void)
{
    return mac_irq_count;
}

unsigned int bl808_wifi_vendor_mac_poll_irq_count(void)
{
    return mac_poll_irq_count;
}

unsigned int bl808_wifi_vendor_mac_trap_irq_count(void)
{
    return mac_trap_irq_count;
}

unsigned int bl808_wifi_vendor_ipc_trap_irq_count(void)
{
    return ipc_trap_irq_count;
}

unsigned int bl808_wifi_vendor_ipc_poll_irq_count(void)
{
    return ipc_poll_irq_count;
}

static void vendor_print_char(char c)
{
    volatile uint32_t *uart_fifo_cfg1 = (volatile uint32_t *)0x2000A084UL;
    volatile uint32_t *uart_wdata = (volatile uint32_t *)0x2000A088UL;
    uint32_t timeout;
    if (c == '\n') {
#ifdef BL808_WIFI_VENDOR_LOG_TO_VALIDATION_BUFFER
        if (hw_validation_log_byte) {
            hw_validation_log_byte('\r');
        }
#endif
        timeout = 1000000UL;
        while (((*uart_fifo_cfg1) & 0x3fUL) == 0 && timeout--) {
        }
        *uart_wdata = '\r';
    }
#ifdef BL808_WIFI_VENDOR_LOG_TO_VALIDATION_BUFFER
    if (hw_validation_log_byte) {
        hw_validation_log_byte((uint8_t)c);
    }
#endif
    timeout = 1000000UL;
    while (((*uart_fifo_cfg1) & 0x3fUL) == 0 && timeout--) {
    }
    *uart_wdata = (uint32_t)(uint8_t)c;
}

static void vendor_puts_raw(const char *s)
{
    if (!s) {
        return;
    }
    while (*s) {
        vendor_print_char(*s++);
    }
}

static void validation_puts_raw(const char *s)
{
#ifndef BL808_WIFI_VENDOR_LOG_TO_VALIDATION_BUFFER
    if (!s || !hw_validation_log_byte) {
        return;
    }
    while (*s) {
        hw_validation_log_byte((uint8_t)*s++);
    }
#else
    (void)s;
#endif
}

static void vendor_print_u32(uint32_t value, unsigned int base)
{
    char buf[11];
    unsigned int pos = 0;
    if (value == 0) {
        vendor_print_char('0');
        return;
    }
    while (value && pos < sizeof(buf)) {
        unsigned int d = value % base;
        buf[pos++] = (char)(d < 10 ? ('0' + d) : ('A' + d - 10));
        value /= base;
    }
    while (pos) {
        vendor_print_char(buf[--pos]);
    }
}

static void vendor_vprintf(const char *fmt, va_list ap)
{
    const char *p = fmt;
    if (!fmt) {
        return;
    }
    while (p && *p) {
        if (*p != '%') {
            vendor_print_char(*p++);
            continue;
        }
        p++;
        while (*p == '0' || *p == '-' || *p == '+' || *p == ' ' || *p == '#') {
            p++;
        }
        while (*p >= '0' && *p <= '9') {
            p++;
        }
        if (*p == 'l') {
            p++;
            if (*p == 'l') {
                p++;
            }
        }
        switch (*p) {
        case 's':
            vendor_puts_raw(va_arg(ap, const char *));
            break;
        case 'd':
        case 'i': {
            int v = va_arg(ap, int);
            if (v < 0) {
                vendor_print_char('-');
                v = -v;
            }
            vendor_print_u32((uint32_t)v, 10);
            break;
        }
        case 'u':
            vendor_print_u32(va_arg(ap, unsigned int), 10);
            break;
        case 'p':
            vendor_puts_raw("0x");
            vendor_print_u32((uint32_t)(uintptr_t)va_arg(ap, void *), 16);
            break;
        case 'x':
        case 'X':
            vendor_print_u32(va_arg(ap, unsigned int), 16);
            break;
        case 'c':
            vendor_print_char((char)va_arg(ap, int));
            break;
        case '%':
            vendor_print_char('%');
            break;
        default:
            vendor_print_char('%');
            if (*p) {
                vendor_print_char(*p);
            }
            break;
        }
        if (*p) {
            p++;
        }
    }
}

__attribute__((weak)) int printf(const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    vendor_vprintf(fmt, ap);
    va_end(ap);
    return 0;
}

__attribute__((weak)) int puts(const char *s)
{
    vendor_puts_raw(s);
    vendor_puts_raw("\r\n");
    return 0;
}

int snprintf(char *str, size_t size, const char *fmt, ...)
{
    (void)fmt;
    if (size) {
        str[0] = '\0';
    }
    return 0;
}

static void os_printf(const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    vendor_vprintf(fmt, ap);
    va_end(ap);
}

static void os_puts(const char *s)
{
    vendor_puts_raw(s);
}

static void os_assert(const char *file, int line, const char *func,
                      const char *expr)
{
    vendor_puts_raw("[WIFI] assert ");
    vendor_puts_raw(file ? file : "?");
    vendor_print_char(':');
    vendor_print_u32((uint32_t)line, 10);
    vendor_print_char(' ');
    vendor_puts_raw(func ? func : "?");
    vendor_print_char(' ');
    vendor_puts_raw(expr ? expr : "?");
    vendor_puts_raw("\r\n");
    while (1) {
        raw_delay(1000);
    }
}

static uint32_t os_enter_critical(void)
{
    return 0;
}

static void os_exit_critical(uint32_t level)
{
    (void)level;
}

static int os_msleep(long ms)
{
    uint64_t deadline = read_mtime_us() + (uint64_t)ms * 1000ULL;

    while ((int64_t)(read_mtime_us() - deadline) < 0) {
        vendor_poll_once();
        delay_mtime_us(100);
    }
    return 0;
}

static int os_adapter_sleep(unsigned int seconds)
{
    return os_msleep((long)seconds * 1000L);
}

static BL_EventGroup_t os_event_group_create(void)
{
    return (BL_EventGroup_t)calloc(1, sizeof(struct simple_event_group));
}

static void os_event_group_delete(BL_EventGroup_t event)
{
    free(event);
}

static uint32_t os_event_group_send(BL_EventGroup_t event, uint32_t bits)
{
    struct simple_event_group *g = (struct simple_event_group *)event;
    if (g) {
        g->bits |= bits;
        return g->bits;
    }
    return 0;
}

static uint32_t os_event_group_wait(BL_EventGroup_t event,
                                    uint32_t bits_to_wait_for,
                                    int clear_on_exit,
                                    int wait_for_all_bits,
                                    uint32_t block_time_tick)
{
    struct simple_event_group *g = (struct simple_event_group *)event;
    uint32_t loops = block_time_tick ? block_time_tick * 64u : 1u;
    if (!g) {
        return 0;
    }
    while (block_time_tick == BL_OS_WAITING_FOREVER || loops--) {
        uint32_t bits = g->bits & bits_to_wait_for;
        int matched = wait_for_all_bits ? (bits == bits_to_wait_for) : (bits != 0);
        if (matched) {
            if (clear_on_exit) {
                g->bits &= ~bits_to_wait_for;
            }
            return bits;
        }
        vendor_poll_once();
        raw_delay(128);
    }
    return 0;
}

static int os_event_register(int type, void *cb, void *arg)
{
    (void)type;
    (void)cb;
    (void)arg;
    return 0;
}

static int os_event_notify(int evt, int val)
{
    (void)evt;
    (void)val;
    return 0;
}

static int os_task_create(const char *name, void *entry, uint32_t stack_depth,
                          void *param, uint32_t prio,
                          BL_TaskHandle_t task_handle)
{
    (void)name;
    (void)entry;
    (void)stack_depth;
    (void)param;
    (void)prio;
    (void)task_handle;
    return 0;
}

static void os_task_delete(BL_TaskHandle_t task_handle)
{
    (void)task_handle;
}

static BL_TaskHandle_t os_task_get_current_task(void)
{
    return (BL_TaskHandle_t)1;
}

static BL_TaskHandle_t os_task_notify_create(void)
{
    return (BL_TaskHandle_t)1;
}

static void os_task_notify(BL_TaskHandle_t task_handle)
{
    (void)task_handle;
}

static void os_task_wait(BL_TaskHandle_t task_handle, uint32_t tick)
{
    (void)task_handle;
    os_event_group_wait(NULL, 0, 0, 0, tick);
}

static void os_noop_void(void)
{
}

static void os_irq_attach(int32_t n, void *f, void *arg)
{
    (void)arg;

    if (f && n >= 0) {
        bl808_register_trap_handler((uint32_t)n, (void (*)(void))f);
    }
}

static void os_irq_enable(int32_t n)
{
    if (n >= 0) {
        bl808_enable_peripheral_irq((uint32_t)n, 1);
    }
}

static void os_irq_disable(int32_t n)
{
    if (n >= 0) {
        bl808_disable_peripheral_irq((uint32_t)n);
    }
}

static void *os_workqueue_create(void)
{
    return NULL;
}

static int os_workqueue_submit(void *work, void *worker, void *argv, long tick)
{
    (void)work;
    (void)worker;
    (void)argv;
    (void)tick;
    return 0;
}

static BL_Timer_t os_timer_create(void *func, void *argv)
{
    (void)func;
    (void)argv;
    return (BL_Timer_t)calloc(1, 4);
}

static int os_timer_delete(BL_Timer_t timerid, uint32_t tick)
{
    (void)tick;
    free(timerid);
    return 0;
}

static int os_timer_start(BL_Timer_t timerid, long t_sec, long t_nsec)
{
    (void)timerid;
    (void)t_sec;
    (void)t_nsec;
    return 0;
}

static BL_Sem_t os_sem_create(uint32_t init)
{
    struct simple_event_group *g = calloc(1, sizeof(*g));
    if (g) {
        g->bits = init;
    }
    return (BL_Sem_t)g;
}

static void os_sem_delete(BL_Sem_t semphr)
{
    free(semphr);
}

static int32_t os_sem_take(BL_Sem_t semphr, uint32_t tick)
{
    uint32_t bits = os_event_group_wait((BL_EventGroup_t)semphr, 1, 1, 1, tick);
    return bits ? 0 : -1;
}

static int32_t os_sem_give(BL_Sem_t semphr)
{
    os_event_group_send((BL_EventGroup_t)semphr, 1);
    return 0;
}

static BL_Mutex_t os_mutex_create(void)
{
    return (BL_Mutex_t)1;
}

static void os_mutex_delete(BL_Mutex_t mutex)
{
    (void)mutex;
}

static int32_t os_mutex_lock(BL_Mutex_t mutex)
{
    (void)mutex;
    return 0;
}

static int32_t os_mutex_unlock(BL_Mutex_t mutex)
{
    (void)mutex;
    return 0;
}

static BL_MessageQueue_t os_queue_create(uint32_t queue_len, uint32_t item_size)
{
    struct simple_queue *q = calloc(1, sizeof(*q) + queue_len * item_size);
    if (q) {
        q->item_size = item_size;
        q->depth = queue_len;
    }
    return (BL_MessageQueue_t)q;
}

static void os_queue_delete(BL_MessageQueue_t queue)
{
    free(queue);
}

static int os_queue_send_wait(BL_MessageQueue_t queue, void *item, uint32_t len,
                              uint32_t ticks, int prio)
{
    struct simple_queue *q = (struct simple_queue *)queue;
    uint8_t *slot;
    (void)ticks;
    (void)prio;
    if (!q || len != q->item_size || ((q->write_idx - q->read_idx) >= q->depth)) {
        return -1;
    }
    slot = q->storage + (q->write_idx % q->depth) * q->item_size;
    memcpy(slot, item, q->item_size);
    q->write_idx++;
    return 0;
}

static int os_queue_send(BL_MessageQueue_t queue, void *item, uint32_t len)
{
    return os_queue_send_wait(queue, item, len, 0, 0);
}

static int os_queue_recv(BL_MessageQueue_t queue, void *item, uint32_t len,
                         uint32_t tick)
{
    struct simple_queue *q = (struct simple_queue *)queue;
    uint32_t loops = tick ? tick : 1u;
    if (!q || len != q->item_size) {
        return -1;
    }
    while (tick == BL_OS_WAITING_FOREVER || loops--) {
        if (q->read_idx != q->write_idx) {
            uint8_t *slot = q->storage + (q->read_idx % q->depth) * q->item_size;
            memcpy(item, slot, q->item_size);
            q->read_idx++;
            return 0;
        }
        vendor_poll_once();
        raw_delay(128);
    }
    return -1;
}

static void *os_malloc(unsigned int size)
{
    void *p = malloc(size);
    if (!p) {
        vendor_puts_raw("[WIFI] malloc fail size=");
        vendor_print_u32(size, 10);
        vendor_puts_raw(" used=");
        vendor_print_u32((uint32_t)tlsf_get_used(), 10);
        vendor_puts_raw(" total=");
        vendor_print_u32((uint32_t)tlsf_get_total(), 10);
        vendor_puts_raw(" largest=");
        vendor_print_u32((uint32_t)tlsf_get_largest_free(), 10);
        vendor_puts_raw(" fails=");
        vendor_print_u32((uint32_t)tlsf_get_alloc_fail_count(), 10);
        vendor_puts_raw("\r\n");
    }
    return p;
}

static void os_free(void *p)
{
    free(p);
}

static void *os_zalloc(unsigned int size)
{
    return calloc(1, size);
}

static uint64_t os_get_time_ms(void)
{
    return read_mtime_us() / 1000ULL;
}

static uint32_t os_get_tick(void)
{
    return (uint32_t)os_get_time_ms();
}

static void os_log_write(uint32_t level, const char *tag, const char *file,
                         int line, const char *format, ...)
{
    (void)level;
    (void)tag;
    (void)file;
    (void)line;
    va_list ap;
    va_start(ap, format);
    vendor_vprintf(format, ap);
    va_end(ap);
}

static int os_task_notify_isr(BL_TaskHandle_t task_handle)
{
    (void)task_handle;
    return 0;
}

static void os_yield_from_isr(int xYield)
{
    (void)xYield;
}

static unsigned int os_ms_to_tick(unsigned int ms)
{
    return ms;
}

static BL_TimeOut_t os_set_timeout(void)
{
    return (BL_TimeOut_t)os_get_tick();
}

static int os_check_timeout(BL_TimeOut_t xTimeOut, BL_TickType_t *xTicksToWait)
{
    (void)xTimeOut;
    if (xTicksToWait && *xTicksToWait) {
        (*xTicksToWait)--;
        return 0;
    }
    return 1;
}

bl_ops_funcs_t g_bl_ops_funcs = {
    ._version = BL_OS_ADAPTER_VERSION,
    ._printf = os_printf,
    ._puts = os_puts,
    ._assert = os_assert,
    ._init = 0,
    ._enter_critical = os_enter_critical,
    ._exit_critical = os_exit_critical,
    ._msleep = os_msleep,
    ._sleep = os_adapter_sleep,
    ._event_group_create = os_event_group_create,
    ._event_group_delete = os_event_group_delete,
    ._event_group_send = os_event_group_send,
    ._event_group_wait = os_event_group_wait,
    ._event_register = os_event_register,
    ._event_notify = os_event_notify,
    ._task_create = os_task_create,
    ._task_delete = os_task_delete,
    ._task_get_current_task = os_task_get_current_task,
    ._task_notify_create = os_task_notify_create,
    ._task_notify = os_task_notify,
    ._task_wait = os_task_wait,
    ._lock_gaint = os_noop_void,
    ._unlock_gaint = os_noop_void,
    ._irq_attach = os_irq_attach,
    ._irq_enable = os_irq_enable,
    ._irq_disable = os_irq_disable,
    ._workqueue_create = os_workqueue_create,
    ._workqueue_submit_hp = os_workqueue_submit,
    ._workqueue_submit_lp = os_workqueue_submit,
    ._timer_create = os_timer_create,
    ._timer_delete = os_timer_delete,
    ._timer_start_once = os_timer_start,
    ._timer_start_periodic = os_timer_start,
    ._sem_create = os_sem_create,
    ._sem_delete = os_sem_delete,
    ._sem_take = os_sem_take,
    ._sem_give = os_sem_give,
    ._mutex_create = os_mutex_create,
    ._mutex_delete = os_mutex_delete,
    ._mutex_lock = os_mutex_lock,
    ._mutex_unlock = os_mutex_unlock,
    ._queue_create = os_queue_create,
    ._queue_delete = os_queue_delete,
    ._queue_send_wait = os_queue_send_wait,
    ._queue_send = os_queue_send,
    ._queue_recv = os_queue_recv,
    ._malloc = os_malloc,
    ._free = os_free,
    ._zalloc = os_zalloc,
    ._get_time_ms = os_get_time_ms,
    ._get_tick = os_get_tick,
    ._log_write = os_log_write,
    ._task_notify_isr = os_task_notify_isr,
    ._yield_from_isr = os_yield_from_isr,
    ._ms_to_tick = os_ms_to_tick,
    ._set_timeout = os_set_timeout,
    ._check_timeout = os_check_timeout,
};

err_t netifapi_netif_add(struct netif *netif, const ip4_addr_t *ipaddr,
                         const ip4_addr_t *netmask, const ip4_addr_t *gw,
                         void *state, netif_init_fn init,
                         netif_input_fn input)
{
    (void)ipaddr;
    (void)netmask;
    (void)gw;
    netif->state = state;
    netif->input = input;
    return init ? init(netif) : 0;
}

err_t netifapi_netif_common(struct netif *netif, netifapi_void_fn voidfunc,
                            netifapi_errt_fn errtfunc)
{
    if (voidfunc) {
        voidfunc(netif);
    }
    if (errtfunc) {
        return errtfunc(netif);
    }
    return 0;
}

err_t netifapi_netif_set_addr(struct netif *netif, const ip4_addr_t *ipaddr,
                              const ip4_addr_t *netmask, const ip4_addr_t *gw)
{
    if (ipaddr) {
        netif->ip_addr.addr = ipaddr->addr;
    }
    if (netmask) {
        netif->netmask.addr = netmask->addr;
    }
    if (gw) {
        netif->gw.addr = gw->addr;
    }
    return 0;
}

void netifapi_netif_set_default(struct netif *netif)
{
    netif_set_default(netif);
}

void netifapi_netif_set_up(struct netif *netif)
{
    netif_set_up(netif);
}

/* Iter 2.A.0 step 3: vendor netifapi.c is gated behind LWIP_NETIF_API=1
 * which we don't enable. SDK files (bl_rx.c) call these. Provide thin
 * stubs that delegate to vendor lwIP's netif_set_link_up/down. */
err_t netifapi_netif_set_link_up(struct netif *netif)
{
    netif_set_link_up(netif);
    return ERR_OK;
}

err_t netifapi_netif_set_link_down(struct netif *netif)
{
    netif_set_link_down(netif);
    return ERR_OK;
}

err_t tcpip_input(struct pbuf *p, struct netif *inp)
{
    (void)inp;
    pbuf_free(p);
    return 0;
}

uint32_t inet_addr(const char *cp)
{
    return ipaddr_addr(cp);
}

int aos_post_event(uint16_t type, uint16_t code, unsigned long value)
{
    (void)type;
    (void)code;
    (void)value;
    return 0;
}

int aos_register_event_filter(uint16_t type, void *cb, void *private_data)
{
    (void)type;
    (void)cb;
    (void)private_data;
    return 0;
}

int aos_post_delayed_action(int ms, void *action, void *arg)
{
    (void)ms;
    (void)action;
    (void)arg;
    return 0;
}

int bl_pm_init(void) { return 0; }
int bl_pm_deinit(void) { return 0; }
int bl_pm_state_run(void) { return 0; }
int bl_pm_capacity_set(enum PM_LEVEL level) { (void)level; return 0; }
int bl_pm_event_register(enum PM_EVEMT event, uint32_t code, uint32_t cap_bit,
                         uint16_t priority, bl_pm_cb_t ops, void *arg,
                         enum PM_EVENT_ABLE enable)
{
    (void)event;
    (void)code;
    (void)cap_bit;
    (void)priority;
    (void)ops;
    (void)arg;
    (void)enable;
    return 0;
}
int bl_pm_event_switch(enum PM_EVEMT event, uint32_t code, enum PM_EVENT_ABLE enable)
{
    (void)event;
    (void)code;
    (void)enable;
    return 0;
}
int pm_post_event(enum PM_EVEMT event, uint32_t code, uint32_t *retval)
{
    (void)event;
    (void)code;
    if (retval) {
        *retval = 0;
    }
    return 0;
}

wifi_hosal_funcs_t g_wifi_hosal_funcs = {
    .efuse_read_mac = (int (*)(uint8_t *))bl_wifi_mac_addr_get,
    .rf_turn_on = hosal_wifi_ret_zero,
    .rf_turn_off = hosal_wifi_ret_zero,
    .adc_device_get = (hosal_adc_dev_t *(*)(void))hosal_wifi_ret_zero,
    .adc_tsen_value_get = (int (*)(hosal_adc_dev_t *))hosal_wifi_ret_zero,
    .pm_init = bl_pm_init,
    .pm_event_register = bl_pm_event_register,
    .pm_deinit = bl_pm_deinit,
    .pm_state_run = bl_pm_state_run,
    .pm_capacity_set = bl_pm_capacity_set,
    .pm_post_event = pm_post_event,
    .pm_event_switch = bl_pm_event_switch,
};

int bl_wifi_clock_enable(void)
{
    volatile uint32_t *wifi_cfg0 = (volatile uint32_t *)(0x20000000UL + 0x3B0UL);
    uint32_t reg = *wifi_cfg0;
    bl808_wifi_vendor_prepare_wireless_domain();
    reg = (reg & ~0xFUL) | 0x1UL;
    *wifi_cfg0 = reg;
    return 0;
}

int bl_wifi_enable_irq(void)
{
    bl808_register_trap_handler(BL808_IRQ_WIFI, bl808_wifi_vendor_mac_irq_trampoline);
    bl808_register_trap_handler(BL808_IRQ_WIFI_IPC_PUBLIC, bl808_wifi_vendor_ipc_irq_trampoline);
    bl808_enable_peripheral_irq(BL808_IRQ_WIFI, 1);
    bl808_enable_peripheral_irq(BL808_IRQ_WIFI_IPC_PUBLIC, 1);
    return 0;
}

int bl_wifi_mac_addr_get(uint8_t mac[6])
{
    static const uint8_t fallback[6] = {0x18, 0xB9, 0x05, 0x00, 0x00, 0x01};
    memcpy(mac, fallback, 6);
    return 0;
}

typedef long vendor_os_time_t;

struct os_time {
    vendor_os_time_t sec;
    long usec;
};

void os_sleep(vendor_os_time_t sec, vendor_os_time_t usec)
{
    long ms = (long)sec * 1000L + (long)(usec / 1000L);
    if (ms <= 0) {
        ms = 1;
    }
    os_msleep(ms);
}

int os_get_time(struct os_time *t)
{
    uint64_t ms;
    if (!t) {
        return -1;
    }
    ms = os_get_time_ms();
    t->sec = (vendor_os_time_t)(ms / 1000u);
    t->usec = (long)((ms % 1000u) * 1000u);
    return 0;
}

static uint32_t vendor_random_state = 0x6d2b79f5u;

static uint32_t vendor_random_u32(void)
{
    uint32_t x = vendor_random_state;
    x ^= x << 13;
    x ^= x >> 17;
    x ^= x << 5;
    vendor_random_state = x ? x : 0x6d2b79f5u;
    return vendor_random_state;
}

unsigned long os_random(void)
{
    return vendor_random_u32();
}

int os_get_random(unsigned char *buf, size_t len)
{
    size_t i;
    if (!buf) {
        return -1;
    }
    for (i = 0; i < len; i++) {
        if ((i & 3u) == 0u) {
            vendor_random_u32();
        }
        buf[i] = (uint8_t)(vendor_random_state >> ((i & 3u) * 8u));
    }
    return 0;
}

void *wpa_supplicant_malloc(size_t size)
{
    return malloc(size);
}

void *wpa_supplicant_realloc(void *ptr, size_t size)
{
    return realloc(ptr, size);
}

void *wpa_supplicant_zalloc(size_t nmemb, size_t size)
{
    return calloc(nmemb, size);
}

void wpa_supplicant_free(void *ptr)
{
    free(ptr);
}

void wpa_supplicant_bzero(void *s, size_t n)
{
    memset(s, 0, n);
}

void *pvPortMalloc(size_t size)
{
    return malloc(size);
}

void *pvPortRealloc(void *ptr, size_t size)
{
    return realloc(ptr, size);
}

void *pvPortCalloc(size_t count, size_t size)
{
    return calloc(count, size);
}

void vPortFree(void *ptr)
{
    free(ptr);
}

void vTaskDelay(uint32_t ticks)
{
    os_msleep((long)(ticks ? ticks : 1u));
}

uint32_t xTaskGetTickCount(void)
{
    return os_get_tick();
}

void __assert_func(const char *file, int line, const char *func, const char *expr)
{
    os_assert(file, line, func, expr);
}

#ifndef BL808_WIFI_VENDOR_FULL_SUPPLICANT
int bl_supplicant_init(void)
{
    return 0;
}

int wpa_parse_wpa_ie_wrapper(const uint8_t *wpa_ie, size_t wpa_ie_len, void *data)
{
    (void)wpa_ie;
    (void)wpa_ie_len;
    memset(data, 0, 36);
    return -1;
}

int pbkdf2_sha1(const char *passphrase, const char *ssid, size_t ssid_len,
                int iterations, uint8_t *buf, size_t buflen)
{
    uint32_t acc = 0x12345678u;
    size_t i;
    (void)iterations;
    for (i = 0; passphrase && passphrase[i]; i++) {
        acc = (acc * 33u) ^ (uint8_t)passphrase[i];
    }
    for (i = 0; ssid && i < ssid_len; i++) {
        acc = (acc * 33u) ^ (uint8_t)ssid[i];
    }
    for (i = 0; i < buflen; i++) {
        acc = acc * 1664525u + 1013904223u;
        buf[i] = (uint8_t)(acc >> 24);
    }
    return 0;
}
#endif

void utils_bin2hex(char *dst, const void *src, size_t src_len)
{
    static const char hex[] = "0123456789abcdef";
    const uint8_t *in = (const uint8_t *)src;
    size_t i;
    for (i = 0; i < src_len; i++) {
        dst[i * 2] = hex[in[i] >> 4];
        dst[i * 2 + 1] = hex[in[i] & 15];
    }
    dst[src_len * 2] = '\0';
}

int utils_tlv_bl_unpack_auto(uint32_t *buf, int buf_sz, uint16_t type, void *arg1)
{
    (void)buf;
    (void)buf_sz;
    (void)type;
    (void)arg1;
    return 0;
}

int utils_tlv_bl_pack_auto(uint32_t *buf, int buf_sz, uint16_t type, void *arg1)
{
    (void)buf;
    (void)buf_sz;
    (void)type;
    (void)arg1;
    return 0;
}

void utils_crc32_stream_init(void *ctx)
{
    memset(ctx, 0, 4);
}

void utils_crc32_stream_feed_block(void *ctx, uint8_t *data, uint32_t len)
{
    uint32_t *crc = (uint32_t *)ctx;
    while (len--) {
        *crc = (*crc << 5) ^ (*crc >> 27) ^ *data++;
    }
}

uint32_t utils_crc32_stream_results(void *ctx)
{
    return *(uint32_t *)ctx;
}

void utils_list_init(struct utils_list *list)
{
    list->first = NULL;
    list->last = NULL;
}

void utils_list_pool_init(struct utils_list *list, void *pool, size_t elmt_size,
                          unsigned int elmt_cnt, void *default_value)
{
    uint8_t *cursor = (uint8_t *)pool;
    utils_list_init(list);
    for (unsigned int i = 0; i < elmt_cnt; i++) {
        if (default_value) {
            memcpy(cursor, default_value, elmt_size);
        } else {
            memset(cursor, 0, elmt_size);
        }
        utils_list_push_back(list, (struct utils_list_hdr *)cursor);
        cursor += elmt_size;
    }
}

void utils_list_push_back(struct utils_list *list, struct utils_list_hdr *hdr)
{
    hdr->next = NULL;
    if (list->last) {
        list->last->next = hdr;
    } else {
        list->first = hdr;
    }
    list->last = hdr;
}

void utils_list_push_front(struct utils_list *list, struct utils_list_hdr *hdr)
{
    hdr->next = list->first;
    list->first = hdr;
    if (!list->last) {
        list->last = hdr;
    }
}

struct utils_list_hdr *utils_list_pop_front(struct utils_list *list)
{
    struct utils_list_hdr *hdr = list->first;
    if (hdr) {
        list->first = hdr->next;
        if (!list->first) {
            list->last = NULL;
        }
        hdr->next = NULL;
    }
    return hdr;
}

void utils_list_remove(struct utils_list *list, struct utils_list_hdr *prev,
                       struct utils_list_hdr *element)
{
    if (!element) {
        return;
    }
    if (prev) {
        prev->next = element->next;
    } else if (list->first == element) {
        list->first = element->next;
    } else {
        return;
    }
    if (list->last == element) {
        list->last = prev;
    }
    element->next = NULL;
}

void utils_list_extract(struct utils_list *list, struct utils_list_hdr *hdr)
{
    struct utils_list_hdr *prev = NULL;
    struct utils_list_hdr *cur = list->first;
    while (cur) {
        if (cur == hdr) {
            utils_list_remove(list, prev, cur);
            return;
        }
        prev = cur;
        cur = cur->next;
    }
}

int utils_list_find(struct utils_list *list, struct utils_list_hdr *hdr)
{
    for (struct utils_list_hdr *cur = list->first; cur; cur = cur->next) {
        if (cur == hdr) {
            return 1;
        }
    }
    return 0;
}

void utils_list_insert(struct utils_list *const list,
                       struct utils_list_hdr *const element,
                       int (*cmp)(struct utils_list_hdr const *elementA,
                                  struct utils_list_hdr const *elementB))
{
    struct utils_list_hdr *prev = NULL;
    struct utils_list_hdr *cur = list->first;
    while (cur && cmp && !cmp(element, cur)) {
        prev = cur;
        cur = cur->next;
    }
    if (prev) {
        element->next = cur;
        prev->next = element;
        if (!cur) {
            list->last = element;
        }
    } else {
        utils_list_push_front(list, element);
    }
}

void utils_list_insert_after(struct utils_list *const list,
                             struct utils_list_hdr *const prev_element,
                             struct utils_list_hdr *const element)
{
    if (!prev_element) {
        utils_list_push_front(list, element);
        return;
    }
    if (!utils_list_find(list, prev_element)) {
        return;
    }
    element->next = prev_element->next;
    prev_element->next = element;
    if (list->last == prev_element) {
        list->last = element;
    }
}

void utils_list_insert_before(struct utils_list *const list,
                              struct utils_list_hdr *const next_element,
                              struct utils_list_hdr *const element)
{
    struct utils_list_hdr *prev = NULL;
    struct utils_list_hdr *cur = list->first;
    while (cur) {
        if (cur == next_element) {
            if (prev) {
                element->next = cur;
                prev->next = element;
            } else {
                utils_list_push_front(list, element);
            }
            return;
        }
        prev = cur;
        cur = cur->next;
    }
}

void utils_list_concat(struct utils_list *list1, struct utils_list *list2)
{
    if (!list2->first) {
        return;
    }
    if (list1->last) {
        list1->last->next = list2->first;
    } else {
        list1->first = list2->first;
    }
    list1->last = list2->last;
    utils_list_init(list2);
}

unsigned int utils_list_cnt(const struct utils_list *const list)
{
    unsigned int count = 0;
    for (struct utils_list_hdr *cur = list->first; cur; cur = cur->next) {
        count++;
    }
    return count;
}

static void connect_cb(void *env, struct wifi_event_sm_connect_ind *ind)
{
    (void)env;
    last_status_code = ind->status_code;
    last_reason_code = ind->reason_code;
    connect_done = ind->status_code;
    wifiMgmr.wifi_mgmr_stat_info.status_code = ind->status_code;
    wifiMgmr.wifi_mgmr_stat_info.reason_code = ind->reason_code;
#ifdef BL808_WIFI_VERBOSE_CONNECT
    if (ind->status_code != 0) {
        vendor_puts_raw("[WIFI] connect failure TX dump\r\n");
        txl_frame_dump();
        txl_cfm_dump();
    }
#endif
}

static void disconnect_cb(void *env, struct wifi_event_sm_disconnect_ind *ind)
{
    (void)env;
    disconnect_done = 1;
    connect_done = -1;
    if (ind) {
        last_status_code = ind->status_code;
        last_reason_code = ind->reason_code;
    }
}

static void beacon_cb(void *env, struct wifi_event_beacon_ind *ind)
{
    (void)env;
    scan_diag_store(ind);
    scan_item_count++;
#ifdef BL808_WIFI_CONNECT_CACHE_HINT
    scan_cache_store(ind);
#endif
    vendor_puts_raw("[WIFI] scan item ch=");
    vendor_print_u32(ind ? ind->channel : 0, 10);
    vendor_puts_raw(" rssi=");
    if (ind && ind->rssi < 0) {
        vendor_puts_raw("-");
        vendor_print_u32((uint32_t)(-ind->rssi), 10);
    } else {
        vendor_print_u32(ind ? (uint32_t)ind->rssi : 0, 10);
    }
#ifdef BL808_WIFI_VERBOSE_SCAN
    if (ind) {
        vendor_puts_raw(" auth=");
        vendor_print_u32((uint32_t)ind->auth, 10);
        vendor_puts_raw(" cipher=");
        vendor_print_u32((uint32_t)ind->cipher, 10);
        vendor_puts_raw(" group=");
        vendor_print_u32((uint32_t)ind->group_cipher, 10);
        vendor_puts_raw(" bssid=");
        vendor_print_mac(ind->bssid);
        vendor_puts_raw(" ssid=");
        vendor_print_ssid(ind->ssid, ind->ssid_len);
    }
#endif
    vendor_puts_raw("\r\n");
}

static void event_cb(void *env, struct wifi_event *event)
{
    (void)env;
    if (event && event->id == WIFI_EVENT_ID_IND_SCAN_DONE) {
        scan_done_count++;
        vendor_puts_raw("[WIFI] scan done\r\n");
    }
}

int bl808_wifi_vendor_init(wifi_conf_t *conf)
{
    wifi_conf_t local_conf;
    int ret;
    if (wifi_started) {
        return 0;
    }
    memset(&wifiMgmr, 0, sizeof(wifiMgmr));
    memset(&local_conf, 0, sizeof(local_conf));
    local_conf.country_code[0] = 'U';
    local_conf.country_code[1] = 'S';
    if (conf && conf->country_code[0]) {
        local_conf.country_code[0] = conf->country_code[0];
        local_conf.country_code[1] = conf->country_code[1] ? conf->country_code[1] : 'S';
    }
    bl808_wifi_vendor_fw_start();
    host_poll_enabled = 1;
    ret = bl606a0_wifi_init(&local_conf);
    if (ret != 0) {
        vendor_puts_raw("[WIFI] bl606a0_wifi_init rc=");
        vendor_print_u32((uint32_t)ret, 10);
        vendor_puts_raw("\r\n");
    } else {
        int phy_ret = bl_main_phy_up();
        if (phy_ret != 0) {
            vendor_puts_raw("[WIFI] bl_main_phy_up rc=");
            if (phy_ret < 0) {
                vendor_puts_raw("-");
                vendor_print_u32((uint32_t)(-phy_ret), 10);
            } else {
                vendor_print_u32((uint32_t)phy_ret, 10);
            }
            vendor_puts_raw("\r\n");
            ret = phy_ret;
        }
        vendor_poll_for(2000);
    }
    wifi_started = (ret == 0);
    wifiMgmr.ready = 1;
    wifiMgmr.ap_bcn_int = 100;
    wifiMgmr.ap_info_ttl_curr = -1;
    wifiMgmr.scan_item_timeout = WIFI_MGMR_CONFIG_SCAN_ITEM_TIMEOUT;
    wifiMgmr.scan_items_lock = os_mutex_create();
    wifiMgmr.wifi_mgmr_stat_info.diagnose_lock = os_mutex_create();
    wifiMgmr.wifi_mgmr_stat_info.diagnose_get_lock = os_mutex_create();
    bl_rx_sm_connect_ind_cb_register(NULL, connect_cb);
    bl_rx_sm_disconnect_ind_cb_register(NULL, disconnect_cb);
    bl_rx_beacon_ind_cb_register(NULL, beacon_cb);
    bl_rx_event_register(NULL, event_cb);
    return ret;
}

wifi_interface_t wifi_mgmr_sta_enable(void)
{
    struct mm_add_if_cfm add_if_cfm;
    ip4_addr_t zero;
    uint8_t mac[6];
    int attempt;
    memset(&zero, 0, sizeof(zero));
    if (!wifi_started) {
        return NULL;
    }
    if (sta_enabled) {
        return &wifiMgmr.wlan_sta;
    }
    wifiMgmr.wlan_sta.mode = 0;
    bl_wifi_mac_addr_get(mac);
#ifdef BL808_WIFI_VERBOSE_CONNECT
    vendor_puts_raw("[WIFI] STA MAC ");
    vendor_print_mac(mac);
    vendor_puts_raw("\r\n");
#endif
    memcpy(wifiMgmr.wlan_sta.mac, mac, sizeof(mac));
    memcpy(wifiMgmr.wlan_sta.netif.hwaddr, mac, sizeof(mac));
    netifapi_netif_add(&wifiMgmr.wlan_sta.netif, &zero, &zero, &zero,
                       NULL, bl606a0_wifi_netif_init, tcpip_input);
    wifiMgmr.wlan_sta.netif.name[0] = 's';
    wifiMgmr.wlan_sta.netif.name[1] = 't';
    netif_set_default(&wifiMgmr.wlan_sta.netif);
    netif_set_up(&wifiMgmr.wlan_sta.netif);
    for (attempt = 0; attempt < 20; attempt++) {
        int rc;
        memset(&add_if_cfm, 0, sizeof(add_if_cfm));
        rc = bl_send_add_if(&wifi_hw, wifiMgmr.wlan_sta.netif.hwaddr,
                            NL80211_IFTYPE_STATION, false, &add_if_cfm);
        if (rc == 0 && add_if_cfm.status == CO_OK) {
            wifi_hw.vif_table[BL_VIF_STA].vif_idx = add_if_cfm.inst_nbr;
            wifi_hw.vif_table[BL_VIF_STA].dev = &wifiMgmr.wlan_sta.netif;
            wifi_hw.vif_table[BL_VIF_STA].up = 1;
            wifi_hw.vif_table[BL_VIF_STA].links_num = 0;
            wifiMgmr.wlan_sta.vif_index = BL_VIF_STA;
            bl808_wifi_vendor_force_own_mac(
                bl808_wifi_vendor_vif_mac(add_if_cfm.inst_nbr), "add-if");
            sta_enabled = 1;
            vendor_poll_for(2000);
            return &wifiMgmr.wlan_sta;
        }
        vendor_puts_raw("[WIFI] add_if retry rc=");
        if (rc < 0) {
            vendor_puts_raw("-");
            vendor_print_u32((uint32_t)(-rc), 10);
        } else {
            vendor_print_u32((uint32_t)rc, 10);
        }
        vendor_puts_raw(" status=");
        vendor_print_u32((uint32_t)add_if_cfm.status, 10);
        vendor_puts_raw("\r\n");
        vendor_poll_for(4000);
    }
    return NULL;
}

struct netif *wifi_mgmr_sta_netif_get(void)
{
    return &wifiMgmr.wlan_sta.netif;
}

struct netif *wifi_mgmr_ap_netif_get(void)
{
    return &wifiMgmr.wlan_ap.netif;
}

int wifi_mgmr_scan(void *data, scan_complete_cb_t cb)
{
    struct mac_addr bssid;
    struct bl_send_scanu_para scanu_para;
    (void)data;
    (void)cb;
    if (!sta_enabled) {
        return -1;
    }
    memset(&bssid, 0xff, sizeof(bssid));
    memset(&scanu_para, 0, sizeof(scanu_para));
    scanu_para.bssid = &bssid;
    scanu_para.mac = wifiMgmr.wlan_sta.netif.hwaddr;
    scanu_para.scan_mode = SCAN_ACTIVE;
    scanu_para.duration_scan = 120000;
    scan_done_count = 0;
    scan_item_count = 0;
    scan_diag_reset();
#ifdef BL808_WIFI_CONNECT_CACHE_HINT
    scan_cache_reset();
#endif
    int rc = bl_send_scanu_req(&wifi_hw, &scanu_para);
    vendor_puts_raw("[WIFI] scan start rc=");
    if (rc < 0) {
        vendor_puts_raw("-");
        vendor_print_u32((uint32_t)(-rc), 10);
    } else {
        vendor_print_u32((uint32_t)rc, 10);
    }
    vendor_puts_raw("\r\n");
    return rc;
}

int wifi_mgmr_sta_connect(wifi_interface_t *interface, char *ssid, char *psk,
                          char *pmk, uint8_t *mac, uint8_t band,
                          uint8_t chan_id)
{
    uint16_t freq = 0;
#ifdef BL808_WIFI_CONNECT_CACHE_HINT
    uint16_t connect_freq;
#endif
    size_t ssid_len;
    size_t psk_len;
    uint32_t flags = WIFI_CONNECT_DEFAULT | WIFI_CONNECT_PMF_CAPABLE;
#ifdef BL808_WIFI_CONNECT_DERIVE_PMK
    char derived_pmk[65];
    uint8_t raw_pmk[32];
#endif
#ifdef BL808_WIFI_CONNECT_CACHE_HINT
    uint8_t cached_bssid[6];
    uint8_t cached_channel = 0;
    int8_t cached_rssi = -128;
    const uint8_t *connect_mac = mac_is_specific(mac) ? mac : NULL;
    int cache_hit = 0;
#endif
    (void)interface;
    if (!sta_enabled || !ssid) {
        return -1;
    }
    freq = wifi_channel_to_freq(chan_id);
    ssid_len = strlen(ssid);
    psk_len = psk ? strlen(psk) : 0;
#ifdef BL808_WIFI_STRICT_CONNECT_VALIDATE
    if (ssid_len > 32 || (psk && ((psk_len < 8 && psk_len != 5) || psk_len > 63))) {
        vendor_puts_raw("[WIFI] connect invalid ssid_len=");
        vendor_print_u32((uint32_t)ssid_len, 10);
        vendor_puts_raw(" psk_len=");
        vendor_print_u32((uint32_t)psk_len, 10);
        vendor_puts_raw("\r\n");
        return -1;
    }
#endif
    /*
     * The SDK connect wrapper passes the original passphrase in req->phrase
     * and only uses req->phrase_pmk when the caller explicitly supplied a
     * 64-character PSK.  Pre-deriving a PMK here made the firmware prefer the
     * injected hex value and consistently fail the 4-way handshake on real APs.
     */
#ifdef BL808_WIFI_CONNECT_DERIVE_PMK
    if (!pmk && psk_len >= 8) {
#ifdef BL808_WIFI_STRICT_CONNECT_VALIDATE
        int pmk_rc = pbkdf2_sha1(psk, ssid, ssid_len, 4096, raw_pmk, sizeof(raw_pmk));
        if (pmk_rc != 0) {
            vendor_puts_raw("[WIFI] connect pbkdf2 rc=-");
            vendor_print_u32((uint32_t)(-pmk_rc), 10);
            vendor_puts_raw("\r\n");
            return -1;
        }
#else
        (void)pbkdf2_sha1(psk, ssid, ssid_len, 4096, raw_pmk, sizeof(raw_pmk));
#endif
        utils_bin2hex(derived_pmk, raw_pmk, sizeof(raw_pmk));
#ifdef BL808_WIFI_CONNECT_HEX_PMK_AS_PASSPHRASE
        psk = derived_pmk;
        psk_len = strlen(derived_pmk);
#else
        pmk = derived_pmk;
#endif
    }
#endif
#ifdef BL808_WIFI_CONNECT_CACHE_HINT
    connect_freq = freq;
    if (scan_cache_find(ssid, ssid_len, mac, cached_bssid,
                        &cached_channel, &cached_rssi)) {
        cache_hit = 1;
        if (mac_is_specific(mac) || !connect_mac) {
            connect_mac = cached_bssid;
        }
        if (connect_freq == 0) {
            connect_freq = wifi_channel_to_freq(cached_channel);
        }
    }
#endif
#ifdef BL808_WIFI_VERBOSE_CONNECT
    vendor_puts_raw("[WIFI] connect ssid_len=");
    vendor_print_u32((uint32_t)ssid_len, 10);
    vendor_puts_raw(" psk_len=");
    vendor_print_u32((uint32_t)psk_len, 10);
    vendor_puts_raw(" pmk_len=");
    vendor_print_u32(pmk ? (uint32_t)strlen(pmk) : 0, 10);
    vendor_puts_raw(" chan=");
    vendor_print_u32((uint32_t)chan_id, 10);
    vendor_puts_raw(" freq=");
#ifdef BL808_WIFI_CONNECT_CACHE_HINT
    vendor_print_u32((uint32_t)connect_freq, 10);
    vendor_puts_raw(" hint=");
    if (connect_mac && mac_is_specific(connect_mac)) {
        vendor_print_mac(connect_mac);
        if (cache_hit) {
            vendor_puts_raw(" ch=");
            vendor_print_u32((uint32_t)cached_channel, 10);
            vendor_puts_raw(" rssi=");
            if (cached_rssi < 0) {
                vendor_puts_raw("-");
                vendor_print_u32((uint32_t)(-cached_rssi), 10);
            } else {
                vendor_print_u32((uint32_t)cached_rssi, 10);
            }
        }
        if (cache_hit) {
            vendor_puts_raw(" cache_freq=");
            vendor_print_u32((uint32_t)wifi_channel_to_freq(cached_channel), 10);
        }
    } else {
        vendor_puts_raw("none");
        if (cache_hit) {
            vendor_puts_raw(" cache=");
            vendor_print_mac(cached_bssid);
            vendor_puts_raw(" ch=");
            vendor_print_u32((uint32_t)cached_channel, 10);
            vendor_puts_raw(" rssi=");
            if (cached_rssi < 0) {
                vendor_puts_raw("-");
                vendor_print_u32((uint32_t)(-cached_rssi), 10);
            } else {
                vendor_print_u32((uint32_t)cached_rssi, 10);
            }
            vendor_puts_raw(" cache_freq=");
            vendor_print_u32((uint32_t)wifi_channel_to_freq(cached_channel), 10);
        }
    }
#else
    vendor_print_u32((uint32_t)freq, 10);
    vendor_puts_raw(" hint=none");
#endif
    vendor_puts_raw(" flags=0x");
    vendor_print_u32(flags, 16);
    vendor_puts_raw("\r\n");
#endif
    connect_done = -1;
    last_status_code = -1;
    disconnect_done = 0;
    bl808_wifi_vendor_force_own_mac(
        bl808_wifi_vendor_vif_mac(wifi_hw.vif_table[BL_VIF_STA].vif_idx),
        "connect");
    bl808_wifi_vendor_force_pta_wlan("connect");
#ifdef BL808_WIFI_KEEP_BCN_BIT5
    reg_write32(0x24B00400UL, reg_read32(0x24B00400UL) | 0x20UL);
    bl808_wifi_vendor_dump_mac_regs("keep-bcn-bit5");
#endif
    bl808_wifi_vendor_force_mac_timing_80mhz("connect");
    bl808_wifi_vendor_force_ack_mode("connect");
    bl808_wifi_vendor_dump_tx_power_regs("connect");
    bl808_wifi_vendor_force_response_tx_power("connect");
#ifdef BL808_WIFI_TRACE
    bl808_wifi_trace_rx_all = 1;
#endif
#ifdef BL808_WIFI_CONNECT_CACHE_HINT
    return bl_main_connect((const uint8_t *)ssid, (int)ssid_len,
                           (const uint8_t *)psk, (int)psk_len,
                           (const uint8_t *)pmk, pmk ? (int)strlen(pmk) : 0,
                           connect_mac, band, connect_freq, flags);
#else
    (void)mac;
    (void)band;
    return bl_main_connect((const uint8_t *)ssid, (int)ssid_len,
                           (const uint8_t *)psk, (int)psk_len,
                           (const uint8_t *)pmk, pmk ? (int)strlen(pmk) : 0,
                           NULL, 0, freq, flags);
#endif
}

int wifi_mgmr_sta_disconnect(void)
{
    int rc;
    if (!sta_enabled) {
        return -1;
    }
    rc = bl_main_disconnect();
    vendor_poll_for(4000);
    return rc;
}

int wifi_mgmr_ap_start(wifi_interface_t *interface, char *ssid,
                       int hidden_ssid, char *passwd, int channel)
{
    int rc;
    (void)interface;
    if (!sta_enabled || !ssid || channel <= 0) {
        return -1;
    }
    rc = bl_main_apm_start(ssid, passwd, channel, (uint8_t)hidden_ssid,
                           wifiMgmr.ap_bcn_int);
    ap_enabled = (rc == 0);
    return rc;
}

int wifi_mgmr_ap_stop(wifi_interface_t *interface)
{
    (void)interface;
    if (!ap_enabled) {
        return -1;
    }
    ap_enabled = 0;
    return bl_main_apm_stop();
}

int wifi_mgmr_api_ip_update(void) { return 0; }
int wifi_mgmr_api_ip_got(void) { return 0; }
int wifi_mgmr_ext_dump_needed(void) { return 0; }
int wifi_mgmr_scan_complete_notify(void)
{
    scan_done_count++;
    vendor_puts_raw("[WIFI] scan complete notify\r\n");
    return 0;
}
int wifi_netif_dhcp_start(struct netif *netif) { (void)netif; return 0; }
int wifi_netif_dhcp_stop(struct netif *netif) { (void)netif; return 0; }
