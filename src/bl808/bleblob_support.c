#include <stdarg.h>
#include <stddef.h>
#include <stdint.h>

extern void *malloc(size_t size);
extern void free(void *ptr);
extern void *memset(void *s, int c, size_t n);
extern void srand(unsigned int seed);
extern void hci_send_2_controller(void *param);
extern void hw_validation_log_byte(uint8_t b) __attribute__((weak));
void bleblob_prepare_wireless_domain(void);
static void bleblob_puts_raw(const char *s);
#ifdef BL808_BLEBLOB_TRACE_INIT
static void bleblob_trace(const char *stage);
#endif
#ifdef BL808_BLEBLOB_USE_BTBLE
extern void rwip_schedule(void);
extern void __real_rwip_time_get(void *time);
#ifdef BL808_BLEBLOB_USE_QCC743
extern void rwip_restore_ble_reg(void);
extern void rwip_prevent_sleep_clear(uint16_t prv_slp_bit);
extern void rwip_sw_wake_up_set(void);
extern uint8_t btbleongoing;
#endif
#ifdef BL808_BLEBLOB_USE_QCC743
extern uint8_t hci_ext_host;
extern void btble_ke_mem_init(uint8_t type, uint8_t *heap, uint16_t size);
extern void *wl_cfg_get(uint8_t *rmem);
extern int8_t wl_init(void);
#ifdef BL808_BLEBLOB_QCC_PHY_INIT
extern void phy_init(const void *config);
extern void rf_init(uint32_t xtalfreq_hz);

#ifdef BL808_BLEBLOB_SKIP_RF_INIT
void rf_init(uint32_t xtalfreq_hz)
{
    (void)xtalfreq_hz;
}
#endif
extern void rf_set_channel(uint8_t bandwidth, uint16_t channel_freq);
extern void wl_bz_rx_optimize(uint16_t channel_freq);
extern void wl_rf_set_bz_target_power_table(int8_t target_pwr_dbm);
extern void wl_rf_set_bz_channel_pwr_comp(void);
#endif
#endif
#else
extern void bflbip_schedule(void);
#endif

#if defined(BL808_BLEBLOB_USE_BTBLE) && defined(BL808_BLEBLOB_SKIP_RF_INIT)
void __wrap_rf_init(uint32_t xtalfreq_hz)
{
    (void)xtalfreq_hz;
}
#endif

#if defined(BL808_BLEBLOB_USE_BTBLE) && defined(BL808_BLEBLOB_RF_RESTORE_INIT)
extern void modem_init_core(uint32_t xtalfreq_hz, uint32_t restore);

void __wrap_rf_init(uint32_t xtalfreq_hz)
{
    modem_init_core(xtalfreq_hz, 1);
}
#endif

#if defined(BL808_BLEBLOB_USE_BTBLE) && defined(BL808_BLEBLOB_USE_BL606P_PHYRF)
extern void __real_rf_init(uint32_t xtalfreq_hz);
extern void phy_init(const void *config);
extern void rf_set_channel(uint8_t bandwidth, uint16_t channel_freq);
extern int rfc_config_power_ble(int32_t pwr_dbm);

static int bleblob_bl606p_rf_ready;

void __wrap_rf_init(uint32_t xtalfreq_hz)
{
    bleblob_prepare_wireless_domain();
    __real_rf_init(xtalfreq_hz);
#ifndef BL808_BLEBLOB_BL606P_NO_PHY_INIT
    phy_init(0);
#endif
#ifndef BL808_BLEBLOB_BL606P_NO_CHANNEL_FORCE
    (void)rfc_config_power_ble(4);
    rf_set_channel(0, 2402);
#endif
}

void bleblob_init_bl606p_phyrf(void)
{
    if (!bleblob_bl606p_rf_ready) {
        __wrap_rf_init(40000000u);
        bleblob_bl606p_rf_ready = 1;
    }
}
#endif

#if defined(BL808_BLEBLOB_USE_BTBLE) && defined(BL808_BLEBLOB_USE_BL616_CONTROLLER)
struct wl_param_t;
extern void ble_controller_deinit(void);

void btble_controller_deinit(void)
{
    ble_controller_deinit();
}

int8_t rfparam_load(struct wl_param_t *param)
{
    (void)param;
    return -1;
}
#endif

#if defined(BL808_BLEBLOB_USE_BTBLE) && defined(BL808_BLEBLOB_USE_BL808_PHYRF)
extern void __real_rf_init(uint32_t xtalfreq_hz);
extern void modem_init_core(uint32_t xtalfreq_hz, uint32_t restore);
extern void *wl_cfg_get(uint8_t *rmem);

static uint8_t bleblob_bl808_wl_rmem[544] __attribute__((aligned(4)));
static int bleblob_bl808_rf_ready;

static void bleblob_bl808_configure_wl(uint32_t xtalfreq_hz)
{
    uint8_t *cfg = (uint8_t *)wl_cfg_get(bleblob_bl808_wl_rmem);
    if (!cfg) {
        return;
    }

    *(uint32_t *)(cfg + 0) = 0;                 /* status */
#ifdef BL808_BLEBLOB_WIFI_COEX
    cfg[4] = 3;                                 /* WL_API_MODE_ALL */
#else
    cfg[4] = 2;                                 /* WL_API_MODE_BZ */
#endif
    cfg[5] = 0;                                 /* en_param_load */
    cfg[6] = 0;                                  /* en_full_cal */
    cfg[7] = 0;                                 /* en_capcode_set */
    *(uint32_t *)(cfg + 8) = xtalfreq_hz;       /* param.xtalfreq_hz */
    *(void **)(cfg + 200) = 0;                  /* param_load */
    *(void **)(cfg + 204) = 0;                  /* capcode_set */
    *(void **)(cfg + 208) = 0;                  /* capcode_get */
    cfg[156] = 4;                               /* BLE target power dBm */
}

void __wrap_rf_init(uint32_t xtalfreq_hz)
{
#ifdef BL808_BLEBLOB_TRACE_INIT
    bleblob_trace("enter rf_init");
#endif
    bleblob_prepare_wireless_domain();
    bleblob_bl808_configure_wl(xtalfreq_hz);
#ifdef BL808_BLEBLOB_BL808_FULL_RF_INIT
    __real_rf_init(xtalfreq_hz);
#else
    modem_init_core(xtalfreq_hz, 1);
#endif
    bleblob_bl808_rf_ready = 1;
#ifdef BL808_BLEBLOB_TRACE_INIT
    bleblob_trace("exit rf_init");
#endif
}
#endif

#if defined(BL808_BLEBLOB_USE_BTBLE) && defined(BL808_BLEBLOB_WRAP_BTBLE_HEAP)
void __wrap_btble_ke_mem_init(uint8_t type, uint8_t *heap, uint16_t size)
{
    (void)type;
    (void)heap;
    (void)size;
}

void *__wrap_btble_ke_malloc(uint32_t size, uint8_t type)
{
    (void)type;
    uint8_t *raw = (uint8_t *)malloc((size_t)size + 4u);
    if (!raw) {
        return 0;
    }
    *(uint16_t *)raw = 0x8338u;
    *(uint16_t *)(raw + 2u) = (uint16_t)size;
    return raw + 4u;
}

void __wrap_btble_ke_free(void *ptr)
{
    if (ptr) {
        free((uint8_t *)ptr - 4u);
    }
}
#endif

typedef struct {
    uint32_t length;
    uint32_t item_size;
    uint32_t head;
    uint32_t tail;
    uint32_t count;
    uint8_t in_use;
    uint8_t storage[32 * 16];
} bleblob_queue_t;

#ifdef BL808_BLEBLOB_USE_BL616_CONTROLLER_M10
static bleblob_queue_t bleblob_queues[8];
#else
static bleblob_queue_t bleblob_queue;
#endif
static void *bleblob_last_queue;
static uint32_t bleblob_task_handle_storage;
static uint32_t bleblob_queue_send_count;
static uint32_t bleblob_queue_recv_count;
static uint32_t bleblob_queue_new_count;
static uint32_t bleblob_queue_new_last_size;
static uint32_t bleblob_queue_new_last_max_msg;
static uint32_t bleblob_queue_new_last_status;
static uint32_t bleblob_hci_controller_count;
static uint32_t bleblob_dm_irq_count;
static uint32_t bleblob_ble_irq_count;
static uint32_t bleblob_rwip_schedule_count;
static uint32_t bleblob_dbg_time_words[3];

#ifdef BL808_BLEBLOB_CAPTURE_LLC_START
uint32_t bleblob_llc_start_seen;
uint32_t bleblob_llc_start_header[4];
uint8_t bleblob_llc_start_msg[64] __attribute__((aligned(4)));
uint32_t bleblob_llc_start_em[64];
uint32_t bleblob_llc_start_rx[64];
uint32_t bleblob_llc_start_tx[16];
uint32_t bleblob_llc_start_regs[8];

extern uint8_t __real_llc_start(uint16_t conhdl, void *param);

uint8_t __wrap_llc_start(uint16_t conhdl, void *param)
{
    if (param) {
        uint8_t *src = (uint8_t *)param;

        bleblob_llc_start_seen++;
        bleblob_llc_start_header[0] = conhdl;
        bleblob_llc_start_header[1] = 56u;
        for (uint32_t i = 0; i < sizeof(bleblob_llc_start_msg); i++) {
            bleblob_llc_start_msg[i] = 0;
        }
        for (uint32_t i = 0; i < 56u; i++) {
            bleblob_llc_start_msg[i] = src[i];
        }
    }

    uint8_t status = __real_llc_start(conhdl, param);
    bleblob_llc_start_header[2] = status;
    if (status == 0) {
        uint32_t activity = 0x28010000u + 0x0120u + 0x0094u * (conhdl & 0x0fu);
        uint32_t tx = 0x28010000u + 0x0558u + 0x0070u * (conhdl & 0x0fu);
        volatile uint32_t *em = (volatile uint32_t *)activity;
        volatile uint32_t *rx = (volatile uint32_t *)0x28010458u;
        volatile uint32_t *txdesc = (volatile uint32_t *)tx;

        for (uint32_t i = 0; i < 64u; i++) {
            bleblob_llc_start_em[i] = em[i];
            bleblob_llc_start_rx[i] = rx[i];
        }
        for (uint32_t i = 0; i < 16u; i++) {
            bleblob_llc_start_tx[i] = txdesc[i];
        }
        bleblob_llc_start_regs[0] = *(volatile uint32_t *)0x28000018u;
        bleblob_llc_start_regs[1] = *(volatile uint32_t *)0x2800001Cu;
        bleblob_llc_start_regs[2] = *(volatile uint32_t *)0x28000024u;
        bleblob_llc_start_regs[3] = *(volatile uint32_t *)0x28000100u;
        bleblob_llc_start_regs[4] = *(volatile uint32_t *)0x28000104u;
        bleblob_llc_start_regs[5] = *(volatile uint32_t *)0x28000828u;
        bleblob_llc_start_regs[6] = *(volatile uint32_t *)0x28000800u;
        bleblob_llc_start_regs[7] = *(volatile uint32_t *)0x280009C0u;
    }
    return status;
}
#endif

static void bleblob_puts_raw(const char *s);
#ifdef BL808_BLEBLOB_TRACE_INIT
static void bleblob_trace(const char *stage);
#endif

#ifdef BL808_BLEBLOB_USE_BTBLE
static void (*bleblob_ble_irq_handler)(void);
static void (*bleblob_dm_irq_handler)(void);
static uint8_t bleblob_ble_irq_enabled;
static uint8_t bleblob_dm_irq_enabled;
#ifdef BL808_BLEBLOB_USE_QCC743
void btblecontroller_software_btdm_reset(void);
#endif
#endif

uint32_t TrapNetCounter;
uint8_t stack_base_svc[2048];
uint8_t stack_len_svc[2048];

static uint32_t bb_reg_read(uint32_t addr)
{
    return *(volatile uint32_t *)addr;
}

static void bb_reg_write(uint32_t addr, uint32_t value)
{
    *(volatile uint32_t *)addr = value;
}

static void bb_reg_or(uint32_t addr, uint32_t value)
{
    bb_reg_write(addr, bb_reg_read(addr) | value);
}

static void bb_reg_update(uint32_t addr, uint32_t mask, uint32_t value)
{
    uint32_t v = bb_reg_read(addr);
    v = (v & ~mask) | (value & mask);
    bb_reg_write(addr, v);
}

static void bleblob_delay_us(uint32_t us)
{
    volatile uint32_t loops = us * 12u;
    while (loops--) {
        __asm__ volatile("nop");
    }
}

static void bleblob_print_char(char c)
{
    volatile uint32_t *uart_fifo_cfg1 = (volatile uint32_t *)0x2000A084u;
    volatile uint32_t *uart_wdata = (volatile uint32_t *)0x2000A088u;
    uint32_t timeout;

    if (c == '\n') {
#ifdef BL808_BLEBLOB_MIRROR_PRINTF_TO_JTAG_LOG
        if (hw_validation_log_byte) {
            hw_validation_log_byte('\r');
        }
#endif
        timeout = 1000000u;
        while (((*uart_fifo_cfg1) & 0x3fu) == 0 && timeout--) {
        }
        *uart_wdata = '\r';
    }

#ifdef BL808_BLEBLOB_MIRROR_PRINTF_TO_JTAG_LOG
    if (hw_validation_log_byte) {
        hw_validation_log_byte((uint8_t)c);
    }
#endif
    timeout = 1000000u;
    while (((*uart_fifo_cfg1) & 0x3fu) == 0 && timeout--) {
    }
    *uart_wdata = (uint32_t)(uint8_t)c;
}

static void bleblob_puts_raw(const char *s)
{
    if (!s) {
        return;
    }
    while (*s) {
        bleblob_print_char(*s++);
    }
}

#ifdef BL808_BLEBLOB_TRACE_INIT
static void bleblob_trace(const char *stage)
{
    bleblob_puts_raw("[BLEBLOB] ");
    bleblob_puts_raw(stage);
    bleblob_puts_raw("\n");
}
#endif

static void bb_sw_reset_cfg0(uint32_t bit)
{
    const uint32_t reg = 0x20000000u + 0x540u;
    uint32_t mask = 1u << bit;
    uint32_t v = bb_reg_read(reg);
    bb_reg_write(reg, v & ~mask);
    (void)bb_reg_read(reg);
    bb_reg_write(reg, bb_reg_read(reg) | mask);
    (void)bb_reg_read(reg);
    bb_reg_write(reg, bb_reg_read(reg) & ~mask);
}

static void bleblob_enable_wireless_clocks(void)
{
    bb_reg_or(0x20000000u + 0x580u, (1u << 5) | (1u << 6) | (1u << 7));
    bb_reg_or(0x20000000u + 0x584u, (1u << 1));
    bb_reg_or(0x20000000u + 0x588u, (1u << 4) | (1u << 8) | (1u << 10));
    bb_reg_update(0x20000000u + 0x3b0u, 0x0fu, 1u);
}

static void bleblob_configure_ble_em(void)
{
    /* Match SDK __EM_SIZE=32K when btble_controller_init is linked. */
    bb_reg_update(0x20000000u + 0x60cu, 0xffu, 0x0fu);
}

static void bleblob_configure_dig_clock(void)
{
    const uint32_t reg = 0x20000000u + 0x250u;
    uint32_t v = bb_reg_read(reg);
    uint32_t dig32_en = v & (1u << 12);

    v &= ~((1u << 24) | (1u << 12));
    bb_reg_write(reg, v);

    v = bb_reg_read(reg);
    v = (v & ~(3u << 28)) | (1u << 28); /* GLB_DIG_CLK_XCLK */
    bb_reg_write(reg, v);

    v = bb_reg_read(reg);
    v &= ~(0x7fu << 16);
    v |= (0x4eu << 16) | (1u << 25) | (1u << 24) | dig32_en;
    bb_reg_write(reg, v);
}

void bleblob_restore_wireless_clocks(void)
{
    bleblob_configure_dig_clock();
    bleblob_enable_wireless_clocks();
}

#ifdef BL808_BLEBLOB_USE_BTBLE
#ifdef BL808_BLEBLOB_REPLACE_RWIP_DRIVER
extern void aes_result_handler(uint8_t status, const uint8_t *result);
extern void btble_ke_event_callback_set(uint8_t event_type, void (*callback)(void));
extern void btble_ke_event_clear(uint8_t event_type);
extern void btble_ke_event_set(uint8_t event_type);
extern void btble_ke_init(void);
extern void btble_ke_mem_init(uint8_t type, uint8_t *heap, uint16_t size);
extern void btble_ke_timer_flush(void);
extern void btble_ke_flush(void);
extern void btble_aes_init(uint8_t init_type);
extern void btble_rf_init(void *rf);
extern void co_djob_initialize(uint8_t init_type);
extern void co_time_init(uint8_t init_type);
extern void hci_initialize(uint8_t init_type);
extern void rwble_init(uint8_t init_type);
extern void sch_alarm_timer_isr(void);
extern void sch_arb_event_start_isr(void);
extern void sch_arb_sw_isr(void);
extern void sch_prog_fifo_isr(void);
extern void sch_prog_skip_isr(uint8_t elt_idx);
extern void sch_arb_init(uint8_t init_type);
extern void sch_prog_init(uint8_t init_type);
extern void sch_plan_init(uint8_t init_type);
extern void sch_alarm_init(uint8_t init_type);
extern void sch_slice_init(uint8_t init_type);

#ifdef BL808_BLEBLOB_TRACE_INIT
extern void __wrap_btble_ke_mem_init(uint8_t type, uint8_t *heap, uint16_t size);
extern void __wrap_btble_ke_timer_flush(void);
extern void __wrap_btble_ke_flush(void);
extern void __wrap_btble_aes_init(uint8_t init_type);
extern void __wrap_btble_rf_init(void *rf);
extern void __wrap_co_time_init(uint8_t init_type);
extern void __wrap_hci_initialize(uint8_t init_type);
extern void __wrap_rwip_driver_init(uint8_t init_type);
extern void __wrap_rwble_init(uint8_t init_type);
extern void __wrap_sch_arb_init(uint8_t init_type);
extern void __wrap_sch_prog_init(uint8_t init_type);
extern void __wrap_sch_plan_init(uint8_t init_type);
extern void __wrap_sch_alarm_init(uint8_t init_type);
extern void __wrap_sch_slice_init(uint8_t init_type);
#define BLEBLOB_CALL_VOID0(name) __wrap_##name()
#define BLEBLOB_CALL_U8(name, arg) __wrap_##name(arg)
#define BLEBLOB_CALL_MEM_INIT(type, heap, size) __wrap_btble_ke_mem_init(type, heap, size)
#define BLEBLOB_CALL_RF_INIT(rf) __wrap_btble_rf_init(rf)
#else
#define BLEBLOB_CALL_VOID0(name) name()
#define BLEBLOB_CALL_U8(name, arg) name(arg)
#define BLEBLOB_CALL_MEM_INIT(type, heap, size) btble_ke_mem_init(type, heap, size)
#define BLEBLOB_CALL_RF_INIT(rf) btble_rf_init(rf)
#endif

uint32_t ble_reg_buf = 0;
uint32_t btble_sleep_duration = 0;
uint32_t ip_reg_buf = 0;
uint8_t rwip_env[0x104] __attribute__((aligned(4))) = {0};

typedef struct {
    uint8_t (*get)(uint8_t param, uint8_t *buf, uint8_t *len);
    uint8_t (*set)(uint8_t param, uint8_t *buf, uint8_t len);
    uint8_t (*del)(uint8_t param);
} bleblob_rwip_param_t;

extern uint8_t *rwip_heap_em;
extern bleblob_rwip_param_t rwip_param;
extern uint8_t rwip_rf[];

static uint8_t bleblob_rwip_rst_state;

static uint8_t bleblob_rwip_param_dummy_get(uint8_t param, uint8_t *buf, uint8_t *len)
{
    (void)param;
    (void)buf;
    (void)len;
    return 1;
}

static uint8_t bleblob_rwip_param_dummy_set(uint8_t param, uint8_t *buf, uint8_t len)
{
    (void)param;
    (void)buf;
    (void)len;
    return 1;
}

static uint8_t bleblob_rwip_param_dummy_del(uint8_t param)
{
    (void)param;
    return 1;
}

static uint32_t *bleblob_rwip_env_word(uint32_t offset)
{
    return (uint32_t *)(void *)(rwip_env + offset);
}

static uint16_t *bleblob_rwip_env_half(uint32_t offset)
{
    return (uint16_t *)(void *)(rwip_env + offset);
}

static uint64_t bleblob_read_mtime_us(void)
{
    volatile uint32_t *mtime = (volatile uint32_t *)0xE000BFF8u;
    uint32_t hi1;
    uint32_t lo;
    uint32_t hi2;

    do {
        hi1 = mtime[1];
        lo = mtime[0];
        hi2 = mtime[1];
    } while (hi1 != hi2);

    return ((uint64_t)hi2 << 32) | lo;
}

static void bleblob_rwip_sample_time(uint32_t words[3])
{
    uint64_t us = bleblob_read_mtime_us();
    uint32_t coarse = (uint32_t)((us / 625u) & 0x0fffffffu);
    uint16_t fine = (uint16_t)(us % 625u);
    uint32_t bts = (uint32_t)(us / 312u);

    if (words) {
        words[0] = coarse;
        words[1] = fine;
        words[2] = bts;
    }

    *bleblob_rwip_env_word(40) = coarse;
    *bleblob_rwip_env_half(44) = fine;
    *bleblob_rwip_env_word(48) = bts;
}

static uint8_t bleblob_rwip_time_reached(uint32_t target_coarse, uint16_t target_fine)
{
    uint32_t now[3];
    int32_t coarse_delta;

    if (target_coarse == 0xffffffffu) {
        return 0;
    }

    bleblob_rwip_sample_time(now);
    coarse_delta = (int32_t)((now[0] - target_coarse) & 0x0fffffffu);
    if (coarse_delta == 0) {
        return (uint16_t)now[1] >= target_fine;
    }
    return coarse_delta > 0 && coarse_delta < 0x08000000;
}

static void bleblob_rwip_crypt_evt_handler(void)
{
    static const uint8_t zero_result[16] = {0};
    btble_ke_event_clear(4);
    aes_result_handler(0, zero_result);
}

void rwip_time_get(void *time)
{
    bleblob_rwip_sample_time((uint32_t *)time);
}

void rwip_driver_init(uint8_t init_type)
{
    *bleblob_rwip_env_word(4) = 0xffffffffu;
    *bleblob_rwip_env_word(16) = 0xffffffffu;
    *bleblob_rwip_env_word(28) = 0xffffffffu;
    *bleblob_rwip_env_word(240) = 0x00050000u;
    *bleblob_rwip_env_word(244) = 0;
    *bleblob_rwip_env_word(248) = 164;
    *bleblob_rwip_env_half(252) = 500;
    rwip_env[254] = 0;
    rwip_env[255] = 50;
    rwip_env[257] = 1;

    if (init_type == 1u) {
        btble_ke_event_callback_set(4, bleblob_rwip_crypt_evt_handler);
        *bleblob_rwip_env_word(0) |= 32u;
    }
}

static void bleblob_rwip_init_params(void)
{
    rwip_param.get = bleblob_rwip_param_dummy_get;
    rwip_param.set = bleblob_rwip_param_dummy_set;
    rwip_param.del = bleblob_rwip_param_dummy_del;
}

static void bleblob_rwip_reset_impl(void)
{
    uint8_t init_type = bleblob_rwip_rst_state;

    BLEBLOB_CALL_VOID0(btble_ke_timer_flush);
    co_djob_initialize(init_type);
    BLEBLOB_CALL_U8(co_time_init, init_type);
    BLEBLOB_CALL_U8(hci_initialize, init_type);
#ifdef BL808_BLEBLOB_TRACE_INIT
    __wrap_rwip_driver_init(init_type);
#else
    rwip_driver_init(init_type);
#endif
    BLEBLOB_CALL_U8(rwble_init, init_type);
    memset(rwip_env + 0x34, 0, 188);
    BLEBLOB_CALL_U8(btble_aes_init, init_type);
    BLEBLOB_CALL_U8(sch_arb_init, init_type);
    BLEBLOB_CALL_U8(sch_prog_init, init_type);
    BLEBLOB_CALL_U8(sch_plan_init, init_type);
    BLEBLOB_CALL_U8(sch_alarm_init, init_type);
    BLEBLOB_CALL_U8(sch_slice_init, init_type);
    BLEBLOB_CALL_VOID0(btble_ke_flush);

    if (init_type == 3u) {
        void (*rf_reset)(void) = *(void (**)(void))(void *)rwip_rf;
        if (rf_reset) {
            rf_reset();
        }
    }
    bleblob_rwip_rst_state = 3u;
}

void __wrap_rwip_init(void)
{
    uint32_t time_words[3] = {0, 0, 0};

#ifdef BL808_BLEBLOB_TRACE_INIT
    bleblob_trace("enter rwip_init");
#endif
    bleblob_rwip_init_params();
    btble_ke_init();
    BLEBLOB_CALL_MEM_INIT(0, rwip_heap_em, 0x1b1cu);
    bleblob_rwip_rst_state = 1u;
    BLEBLOB_CALL_RF_INIT(rwip_rf);
    rwip_time_get(time_words);
    srand(time_words[0] + (uint16_t)time_words[1]);
    BLEBLOB_CALL_U8(hci_initialize, bleblob_rwip_rst_state);
    BLEBLOB_CALL_U8(rwble_init, bleblob_rwip_rst_state);
    memset(rwip_env + 0x34, 0, 188);
#ifdef BL808_BLEBLOB_TRACE_INIT
    __wrap_rwip_driver_init(bleblob_rwip_rst_state);
#else
    rwip_driver_init(bleblob_rwip_rst_state);
#endif
    co_djob_initialize(bleblob_rwip_rst_state);
    BLEBLOB_CALL_U8(co_time_init, bleblob_rwip_rst_state);
    bleblob_rwip_rst_state = 2u;
    bleblob_rwip_reset_impl();
#ifdef BL808_BLEBLOB_TRACE_INIT
    bleblob_trace("exit rwip_init");
#endif
}

void __wrap_rwip_reset(void)
{
#ifdef BL808_BLEBLOB_TRACE_INIT
    bleblob_trace("enter rwip_reset");
#endif
    bleblob_rwip_reset_impl();
#ifdef BL808_BLEBLOB_TRACE_INIT
    bleblob_trace("exit rwip_reset");
#endif
}

void rwip_prevent_sleep_set(uint16_t prv_slp_bit)
{
    *bleblob_rwip_env_word(0) |= prv_slp_bit;
}

void rwip_prevent_sleep_clear(uint16_t prv_slp_bit)
{
    *bleblob_rwip_env_word(0) &= ~((uint32_t)prv_slp_bit);
}

uint32_t rwip_prevent_sleep_get(void)
{
    return *bleblob_rwip_env_word(0);
}

uint16_t rwip_current_drift_get(void)
{
    return *bleblob_rwip_env_half(252);
}

uint16_t rwip_max_drift_get(void)
{
    return *bleblob_rwip_env_half(252);
}

uint8_t rwip_sca_get(void)
{
    return rwip_env[254];
}

void rwip_bts_to_bt_time(uint32_t bts, uint32_t *coarse, uint16_t *fine);

void rwip_timer_co_set(uint32_t target_bts)
{
    uint32_t coarse;
    uint16_t fine;

    rwip_bts_to_bt_time(target_bts, &coarse, &fine);
    *bleblob_rwip_env_word(28) = coarse;
    *bleblob_rwip_env_half(32) = fine;
}

void rwip_timer_alarm_set(uint32_t target_coarse, uint16_t target_fine)
{
    *bleblob_rwip_env_word(16) = target_coarse;
    *bleblob_rwip_env_half(20) = target_fine;
}

void rwip_timer_arb_set(uint32_t target_coarse, uint16_t target_fine)
{
    *bleblob_rwip_env_word(4) = target_coarse;
    *bleblob_rwip_env_half(8) = target_fine;
}

void rwip_aes_encrypt(const uint8_t *input, const uint8_t *key)
{
    static uint8_t result[16];
    uint32_t i;

    (void)key;
    for (i = 0; i < sizeof(result); i++) {
        result[i] = input ? input[i] : 0;
    }
    aes_result_handler(0, result);
}

void rwip_sw_int_req(void)
{
    sch_arb_sw_isr();
}

void rwip_isr(void)
{
    if (bleblob_rwip_time_reached(*bleblob_rwip_env_word(4),
                                  *bleblob_rwip_env_half(8))) {
        *bleblob_rwip_env_word(4) = 0xffffffffu;
        sch_arb_event_start_isr();
    }
    if (bleblob_rwip_time_reached(*bleblob_rwip_env_word(16),
                                  *bleblob_rwip_env_half(20))) {
        *bleblob_rwip_env_word(16) = 0xffffffffu;
        sch_alarm_timer_isr();
    }
    if (bleblob_rwip_time_reached(*bleblob_rwip_env_word(28),
                                  *bleblob_rwip_env_half(32))) {
        *bleblob_rwip_env_word(28) = 0xffffffffu;
        btble_ke_event_set(5);
    }
}

uint32_t rwip_bt_time_to_bts(uint32_t coarse, uint16_t fine)
{
    uint32_t ref_coarse = *bleblob_rwip_env_word(40);
    uint16_t ref_fine = *bleblob_rwip_env_half(44);
    uint32_t ref_bts = *bleblob_rwip_env_word(48);
    int32_t coarse_delta = (int32_t)((coarse - ref_coarse) & 0x0fffffffu);
    int32_t fine_delta = (int32_t)fine - (int32_t)ref_fine;
    int32_t half_slots;

    if (coarse_delta > 0x07ffffff) {
        coarse_delta -= 0x10000000;
    }
    half_slots = (coarse_delta * 625 + fine_delta) / 2;
    return ref_bts + (uint32_t)half_slots;
}

void rwip_bts_to_bt_time(uint32_t bts, uint32_t *coarse, uint16_t *fine)
{
    uint32_t ref_coarse = *bleblob_rwip_env_word(40);
    uint16_t ref_fine = *bleblob_rwip_env_half(44);
    int32_t delta = (int32_t)(bts - *bleblob_rwip_env_word(48));
    int32_t us = (int32_t)ref_fine + delta * 2;

    while (us < 0) {
        us += 625;
        ref_coarse = (ref_coarse - 1u) & 0x0fffffffu;
    }
    while (us >= 625) {
        us -= 625;
        ref_coarse = (ref_coarse + 1u) & 0x0fffffffu;
    }

    if (coarse) {
        *coarse = ref_coarse;
    }
    if (fine) {
        *fine = (uint16_t)us;
    }
}

void rwip_channel_assess_ble(uint8_t channel, uint8_t add, uint32_t timestamp, int8_t rssi)
{
    int8_t *data = (int8_t *)(void *)(rwip_env + 200);

    (void)timestamp;
    (void)rssi;
    if (channel >= 37u) {
        return;
    }
    if (add) {
        if (data[channel] < 3) {
            data[channel]++;
        }
    } else if (data[channel] > -3) {
        data[channel]--;
    }
}

void *rwip_ch_assess_data_ble_get(void)
{
    return rwip_env + 52;
}

void rwip_ch_ass_en_set(uint8_t enable)
{
    rwip_env[257] = enable;
}

uint8_t rwip_ch_ass_en_get(void)
{
    return rwip_env[257];
}

uint32_t rwip_sleep(void)
{
    return 0xffffffffu;
}

uint32_t btble_controller_sleep(void)
{
    return rwip_sleep();
}
#endif

void __wrap_rwip_time_get(void *time)
{
    uint32_t *words = (uint32_t *)time;
#ifdef BL808_BLEBLOB_REPLACE_RWIP_DRIVER
    rwip_time_get(words);
#else
    volatile uint32_t *time0 = (volatile uint32_t *)0x28000100u;
    volatile uint32_t *time1 = (volatile uint32_t *)0x28000104u;
    volatile uint32_t *sched1 = (volatile uint32_t *)0x280009c4u;
    uint32_t coarse;
    uint32_t fine;
    uint32_t sched;
    uint32_t guard;

    bleblob_enable_wireless_clocks();

    coarse = *time0 | 0x80000000u;
    *time0 = coarse;
    guard = 4096u;
    while ((*time0 & 0x80000000u) != 0u && guard-- != 0u) {
    }

    coarse = *time0 & 0x0fffffffu;
    fine = 624u - (*time1 & 0xffffu);
    sched = *sched1;

    if (words) {
        words[0] = coarse;
        words[1] = fine & 0xffffu;
        words[2] = sched;
    }
#endif
}

void bleblob_restore_ble_sleep_state(void)
{
    bleblob_enable_wireless_clocks();
#ifdef BL808_BLEBLOB_USE_QCC743
    btbleongoing = 0;
    rwip_sw_wake_up_set();
    btblecontroller_software_btdm_reset();
    rwip_restore_ble_reg();
    rwip_prevent_sleep_clear(0xffffu);
#endif
    bleblob_enable_wireless_clocks();
}
#endif

static void bleblob_power_on_xtal_wifipll(void)
{
    const uint32_t glb = 0x20000000u;
    const uint32_t aon = 0x2000f000u;
    const uint32_t hbn = 0x2000f000u;
    const uint32_t mm_glb = 0x30007000u;
    const uint32_t hbn_rsv3 = hbn + 0x10cu;

    bb_reg_or(aon + 0x880u, (1u << 0) | (1u << 1) | (1u << 2) |
                             (1u << 4) | (1u << 5));
    bleblob_delay_us(120);

    /* HBN_Set_Xtal_Type(GLB_XTAL_40M): 0x5800 flag plus enum value 4. */
    bb_reg_write(hbn_rsv3, (bb_reg_read(hbn_rsv3) & 0xffff0000u) | 0x5804u);

    if ((bb_reg_read(glb + 0x810u) & (1u << 10)) != 0) {
        bb_reg_or(glb + 0x824u, 1u << 12);
        bb_reg_or(glb + 0x830u, (1u << 31) | (1u << 1) | (1u << 2) |
                                 (1u << 3) | (1u << 4) | (1u << 5));
        bb_reg_or(glb + 0x090u, 1u << 0);
        bb_reg_or(mm_glb + 0x000u, 1u << 0);
        return;
    }

    /* BL808 SDK GLB_Power_On_XTAL_And_PLL_CLK(GLB_XTAL_40M, WIFIPLL). */
    bb_reg_update(glb + 0x810u, (1u << 10) | (1u << 9), 0);
    bb_reg_update(glb + 0x814u, (0x0fu << 8) | (0x03u << 16),
                  (2u << 8) | (1u << 16));
    bb_reg_update(glb + 0x818u, (1u << 8) | (0x03u << 6) | (0x03u << 4),
                  (0u << 8) | (0u << 6) | (2u << 4));
    bb_reg_update(glb + 0x81cu, (1u << 0) | (1u << 8) | (0x03u << 12) |
                                  (0x03u << 14) | (0x07u << 16),
                  (0u << 0) | (1u << 8) | (2u << 12) |
                  (1u << 14) | (3u << 16));
    bb_reg_update(glb + 0x820u, 0x03u << 0, 1u << 0);
    bb_reg_update(glb + 0x824u, 0x07u << 0, 5u << 0);
    bb_reg_update(glb + 0x828u, (0x03ffffffu << 0) | (1u << 28) | (1u << 31),
                  0x01800000u | (1u << 28) | (1u << 31));

    bb_reg_or(glb + 0x810u, 1u << 9);
    bleblob_delay_us(3);
    bb_reg_or(glb + 0x810u, 1u << 10);
    bleblob_delay_us(3);

    bb_reg_or(glb + 0x810u, 1u << 0);
    bleblob_delay_us(2);
    bb_reg_write(glb + 0x810u, bb_reg_read(glb + 0x810u) & ~(1u << 0));
    bleblob_delay_us(2);
    bb_reg_or(glb + 0x810u, 1u << 0);

    bb_reg_or(glb + 0x810u, 1u << 2);
    bleblob_delay_us(2);
    bb_reg_write(glb + 0x810u, bb_reg_read(glb + 0x810u) & ~(1u << 2));
    bleblob_delay_us(2);
    bb_reg_or(glb + 0x810u, 1u << 2);

    bb_reg_or(glb + 0x824u, 1u << 12);
    bb_reg_or(glb + 0x830u, (1u << 31) | (1u << 1) | (1u << 2) |
                             (1u << 3) | (1u << 4) | (1u << 5));
    bleblob_delay_us(75);

    bb_reg_or(glb + 0x090u, 1u << 0);
    bb_reg_or(mm_glb + 0x000u, 1u << 0);
}

void bleblob_prepare_wireless_domain(void)
{
    /* Match the BL808 GLB clock domains used by the SDK wireless bring-up. */
    bleblob_configure_ble_em();
    bleblob_power_on_xtal_wifipll();
    bleblob_configure_dig_clock();
    bleblob_enable_wireless_clocks();
    bb_sw_reset_cfg0(4);   /* WiFi */
    bb_sw_reset_cfg0(8);   /* BTDM */
    bb_sw_reset_cfg0(10);  /* BLE2 */
    bleblob_configure_dig_clock();
    bleblob_enable_wireless_clocks();
}

static void *bb_memcpy(void *dest, const void *src, size_t n)
{
    uint8_t *d = (uint8_t *)dest;
    const uint8_t *s = (const uint8_t *)src;
    while (n--) {
        *d++ = *s++;
    }
    return dest;
}

#if defined(BL808_BLEBLOB_USE_BTBLE) && defined(BL808_BLEBLOB_USE_QCC743)
static uint8_t bleblob_qcc_msg_heap[8192] __attribute__((aligned(4)));
static uint8_t bleblob_qcc_wl_rmem[1024] __attribute__((aligned(4)));
static int bleblob_qcc_wl_ready;

void bleblob_qcc_init_extra_heaps(void)
{
    btble_ke_mem_init(2, bleblob_qcc_msg_heap, sizeof(bleblob_qcc_msg_heap));
}

int bleblob_qcc_init_phyrf(void)
{
    if (bleblob_qcc_wl_ready) {
        return 0;
    }

    bleblob_prepare_wireless_domain();
    uint8_t *cfg = (uint8_t *)wl_cfg_get(bleblob_qcc_wl_rmem);
    if (!cfg) {
        return -1;
    }

    *(uint32_t *)(cfg + 0) = 0;            /* status */
    cfg[4] = 2;                            /* WL_API_MODE_BZ */
    cfg[5] = 0;                            /* en_param_load */
    cfg[6] = 0;                            /* en_full_cal */
    cfg[7] = 0;                            /* en_capcode_set */
    *(uint32_t *)(cfg + 8) = 40000000u;    /* param.xtalfreq_hz */
    *(void **)(cfg + 484) = 0;             /* param_load */
    *(void **)(cfg + 488) = 0;             /* capcode_set */
    *(void **)(cfg + 492) = 0;             /* capcode_get */
    *(void **)(cfg + 496) = 0;             /* log_printf */
    cfg[500] = 0;                          /* log_level */
    cfg[501] = 0;                          /* device_info */

#ifdef BL808_BLEBLOB_QCC_PHY_INIT
    phy_init(0);
    rf_init(40000000u);
    wl_rf_set_bz_target_power_table(4);
    wl_rf_set_bz_channel_pwr_comp();
    wl_bz_rx_optimize(2402);
    rf_set_channel(0, 2402);
#endif

    bleblob_qcc_wl_ready = 1;
    return 0;
}
#endif

void *xQueueGenericCreate(uint32_t length, uint32_t item_size, uint8_t queue_type)
{
    (void)queue_type;
    if (length == 0 || length > 32 || item_size == 0 || item_size > 16) {
        return 0;
    }
#ifdef BL808_BLEBLOB_USE_BL616_CONTROLLER_M10
    for (uint32_t i = 0; i < sizeof(bleblob_queues) / sizeof(bleblob_queues[0]); i++) {
        bleblob_queue_t *queue = &bleblob_queues[i];
        if (queue->in_use) {
            continue;
        }
        queue->length = length;
        queue->item_size = item_size;
        queue->head = 0;
        queue->tail = 0;
        queue->count = 0;
        queue->in_use = 1;
        bleblob_last_queue = queue;
        return queue;
    }
    return 0;
#else
    bleblob_queue.length = length;
    bleblob_queue.item_size = item_size;
    bleblob_queue.head = 0;
    bleblob_queue.tail = 0;
    bleblob_queue.count = 0;
    bleblob_queue.in_use = 1;
    bleblob_last_queue = &bleblob_queue;
    return &bleblob_queue;
#endif
}

int xQueueGenericSend(void *queue_handle, const void *item, uint32_t ticks, uint32_t copy_position)
{
    (void)ticks;
    (void)copy_position;
    bleblob_queue_t *queue = (bleblob_queue_t *)queue_handle;
    if (!queue || !item || queue->count >= queue->length) {
        return 0;
    }
    uint32_t off = queue->tail * queue->item_size;
    bb_memcpy(&queue->storage[off], item, queue->item_size);
    queue->tail = (queue->tail + 1) % queue->length;
    queue->count++;
    if (queue->item_size >= 8 && ((const uint8_t *)item)[0] == 1) {
        bleblob_last_queue = queue;
    }
    bleblob_queue_send_count++;
    return 1;
}

int xQueueGenericSendFromISR(void *queue_handle, const void *item,
                             uint32_t *higher_priority_task_woken,
                             uint32_t copy_position)
{
    int ret = xQueueGenericSend(queue_handle, item, 0, copy_position);
    if (higher_priority_task_woken) {
        *higher_priority_task_woken = ret ? 1 : 0;
    }
    return ret;
}

int xQueueReceive(void *queue_handle, void *item, uint32_t ticks)
{
    (void)ticks;
    bleblob_queue_t *queue = (bleblob_queue_t *)queue_handle;
    if (!queue || !item || queue->count == 0) {
        return 0;
    }
    uint32_t off = queue->head * queue->item_size;
    bb_memcpy(item, &queue->storage[off], queue->item_size);
    queue->head = (queue->head + 1) % queue->length;
    queue->count--;
    bleblob_queue_recv_count++;
    return 1;
}

void vQueueDelete(void *queue_handle)
{
#ifdef BL808_BLEBLOB_USE_BL616_CONTROLLER_M10
    bleblob_queue_t *queue = (bleblob_queue_t *)queue_handle;
    if (!queue) {
        return;
    }
    queue->in_use = 0;
    queue->head = 0;
    queue->tail = 0;
    queue->count = 0;
    if (bleblob_last_queue == queue) {
        bleblob_last_queue = 0;
    }
#else
    (void)queue_handle;
#endif
}

int xTaskCreate(void (*task)(void *), const char *name, uint32_t stack_depth,
                void *param, uint32_t priority, void **task_handle)
{
    (void)task;
    (void)name;
    (void)stack_depth;
    (void)param;
    (void)priority;
    if (task_handle) {
        *task_handle = &bleblob_task_handle_storage;
    }
    return 1;
}

void vTaskDelete(void *task_handle)
{
    (void)task_handle;
}

uint32_t uxTaskPriorityGet(void *task_handle)
{
    (void)task_handle;
    return 5;
}

void vTaskSwitchContext(void)
{
}

void bleblob_poll_for(uint32_t iterations)
{
    for (uint32_t i = 0; i < iterations; i++) {
        bleblob_enable_wireless_clocks();
        uint8_t msg[16];
        if (bleblob_last_queue && xQueueReceive(bleblob_last_queue, msg, 0) == 1) {
            if (msg[0] == 1) {
                void *param = 0;
                bb_memcpy(&param, &msg[4], sizeof(param));
                if (param) {
                    bleblob_enable_wireless_clocks();
#ifdef BL808_BLEBLOB_USE_QCC743
                    hci_ext_host = 0;
#endif
                    hci_send_2_controller(param);
                    bleblob_hci_controller_count++;
                }
            }
        }
#ifdef BL808_BLEBLOB_USE_BTBLE
        if (bleblob_dm_irq_enabled && bleblob_dm_irq_handler) {
            bleblob_dm_irq_handler();
            bleblob_dm_irq_count++;
        }
        if (bleblob_ble_irq_enabled && bleblob_ble_irq_handler) {
            bleblob_ble_irq_handler();
            bleblob_ble_irq_count++;
        }
        rwip_schedule();
        bleblob_rwip_schedule_count++;
#else
        bflbip_schedule();
#endif
    }
}

uint32_t bleblob_dbg_queue_send_count(void)
{
    return bleblob_queue_send_count;
}

uint32_t bleblob_dbg_queue_recv_count(void)
{
    return bleblob_queue_recv_count;
}

uint32_t bleblob_dbg_queue_new_count(void)
{
    return bleblob_queue_new_count;
}

uint32_t bleblob_dbg_queue_new_last_size(void)
{
    return bleblob_queue_new_last_size;
}

uint32_t bleblob_dbg_queue_new_last_max_msg(void)
{
    return bleblob_queue_new_last_max_msg;
}

uint32_t bleblob_dbg_queue_new_last_status(void)
{
    return bleblob_queue_new_last_status;
}

uint32_t bleblob_dbg_hci_controller_count(void)
{
    return bleblob_hci_controller_count;
}

uint32_t bleblob_dbg_dm_irq_enabled(void)
{
#ifdef BL808_BLEBLOB_USE_BTBLE
    return bleblob_dm_irq_enabled;
#else
    return 0;
#endif
}

uint32_t bleblob_dbg_ble_irq_enabled(void)
{
#ifdef BL808_BLEBLOB_USE_BTBLE
    return bleblob_ble_irq_enabled;
#else
    return 0;
#endif
}

uint32_t bleblob_dbg_dm_irq_count(void)
{
    return bleblob_dm_irq_count;
}

uint32_t bleblob_dbg_ble_irq_count(void)
{
    return bleblob_ble_irq_count;
}

uint32_t bleblob_dbg_rwip_schedule_count(void)
{
    return bleblob_rwip_schedule_count;
}

void bleblob_dbg_sample_time(void)
{
#ifdef BL808_BLEBLOB_USE_BTBLE
    uint32_t t[3] = {0, 0, 0};
    __wrap_rwip_time_get(t);
    bleblob_dbg_time_words[0] = t[0];
    bleblob_dbg_time_words[1] = t[1];
    bleblob_dbg_time_words[2] = t[2];
#endif
}

uint32_t bleblob_dbg_time_word(uint32_t index)
{
    if (index >= 3) {
        return 0;
    }
    return bleblob_dbg_time_words[index];
}

uint32_t bleblob_dbg_reg32(uint32_t addr)
{
    return bb_reg_read(addr);
}

__attribute__((weak)) int printf(const char *fmt, ...)
{
    bleblob_puts_raw(fmt);
    return 0;
}

__attribute__((weak)) int puts(const char *s)
{
    bleblob_puts_raw(s);
    bleblob_puts_raw("\n");
    return 0;
}

#if defined(BL808_BLEBLOB_USE_BTBLE) && defined(BL808_BLEBLOB_TRACE_INIT)
#define BLEBLOB_WRAP_VOID0(name)        \
    extern void __real_##name(void);    \
    void __wrap_##name(void)            \
    {                                   \
        bleblob_trace("enter " #name);  \
        __real_##name();                \
        bleblob_trace("exit " #name);   \
    }

#define BLEBLOB_WRAP_U8(name)           \
    extern void __real_##name(uint8_t); \
    void __wrap_##name(uint8_t arg)     \
    {                                   \
        bleblob_trace("enter " #name);  \
        __real_##name(arg);             \
        bleblob_trace("exit " #name);   \
    }

#ifndef BL808_BLEBLOB_REPLACE_RWIP_DRIVER
BLEBLOB_WRAP_VOID0(rwip_init)
#endif
BLEBLOB_WRAP_U8(co_time_init)
BLEBLOB_WRAP_U8(hci_initialize)
#ifndef BL808_BLEBLOB_REPLACE_RWIP_DRIVER
BLEBLOB_WRAP_U8(rwip_driver_init)
#else
void __wrap_rwip_driver_init(uint8_t arg)
{
    bleblob_trace("enter rwip_driver_init");
    rwip_driver_init(arg);
    bleblob_trace("exit rwip_driver_init");
}
#endif
BLEBLOB_WRAP_U8(rwble_init)
BLEBLOB_WRAP_U8(btble_aes_init)
BLEBLOB_WRAP_U8(sch_arb_init)
BLEBLOB_WRAP_U8(sch_prog_init)
BLEBLOB_WRAP_U8(sch_plan_init)
BLEBLOB_WRAP_U8(sch_alarm_init)
BLEBLOB_WRAP_U8(sch_slice_init)
#if defined(BL808_BLEBLOB_USE_BL808_PHYRF) && defined(BL808_BLEBLOB_REPLACE_RWIP_DRIVER)
extern void __real_lld_init(uint8_t arg);
void __wrap_lld_init(uint8_t arg)
{
    bleblob_trace("enter lld_init");
    bleblob_prepare_wireless_domain();
    __real_lld_init(arg);
    bleblob_trace("exit lld_init");
}
#else
BLEBLOB_WRAP_U8(lld_init)
#endif
BLEBLOB_WRAP_U8(llm_init)

extern void __real_btble_ke_timer_flush(void);
void __wrap_btble_ke_timer_flush(void)
{
    bleblob_trace("enter btble_ke_timer_flush");
    __real_btble_ke_timer_flush();
    bleblob_trace("exit btble_ke_timer_flush");
}

extern void __real_btble_ke_flush(void);
void __wrap_btble_ke_flush(void)
{
    bleblob_trace("enter btble_ke_flush");
    __real_btble_ke_flush();
    bleblob_trace("exit btble_ke_flush");
}

extern void __real_btble_rf_init(void *);
void __wrap_btble_rf_init(void *rf)
{
    bleblob_trace("enter btble_rf_init");
    __real_btble_rf_init(rf);
    bleblob_trace("exit btble_rf_init");
}

#undef BLEBLOB_WRAP_VOID0
#undef BLEBLOB_WRAP_U8
#endif

int abs(int value)
{
    return value < 0 ? -value : value;
}

int strncmp(const char *a, const char *b, size_t n)
{
    while (n--) {
        unsigned char ca = (unsigned char)*a++;
        unsigned char cb = (unsigned char)*b++;
        if (ca != cb) {
            return (int)ca - (int)cb;
        }
        if (ca == 0) {
            return 0;
        }
    }
    return 0;
}

long random(void)
{
    static uint32_t state = 0x12345678;
    state = state * 1664525u + 1013904223u;
    return (long)(state & 0x7fffffffu);
}

static uint32_t bleblob_rand_state = 0x12345678;

void srand(unsigned int seed)
{
    bleblob_rand_state = seed ? seed : 0x12345678;
}

int rand(void)
{
    bleblob_rand_state = bleblob_rand_state * 1664525u + 1013904223u;
    return (int)((bleblob_rand_state >> 1) & 0x7fffffffu);
}

double log(double x)
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

__attribute__((weak)) void assert_err(const char *cond, const char *file, int line)
{
    (void)cond;
    (void)file;
    (void)line;
}

void BL602_Delay_US(uint32_t us)
{
    bleblob_delay_us(us);
}

void BL602_Delay_MS(uint32_t ms)
{
    while (ms--) {
        BL602_Delay_US(1000);
    }
}

__attribute__((weak)) void arch_delay_us(uint32_t us)
{
    BL602_Delay_US(us);
}

void arch_delay_ms(uint32_t ms)
{
    BL602_Delay_MS(ms);
}

#if defined(BL808_BLEBLOB_USE_BL616_PHYRF) || defined(BL808_BLEBLOB_USE_BTBLE)
void __wrap_udelay(uint32_t us)
{
    BL602_Delay_US(us);
#ifdef BL808_BLEBLOB_USE_BL808_PHYRF
    uint32_t txcal = bb_reg_read(0x200010b4u);
    if (txcal & 0x01100000u) {
        bb_reg_write(0x200010b4u, txcal & ~0x01100000u);
    }
    uint32_t fcal = bb_reg_read(0x200010acu);
    if ((fcal & 0x00100000u) == 0) {
        bb_reg_write(0x200010acu, fcal | 0x00100000u);
    }
#endif
}

__attribute__((weak)) void __wrap_wait_us(uint32_t us)
{
    BL602_Delay_US(us);
}
#endif

#ifdef BL808_BLEBLOB_USE_BTBLE
#ifdef BL808_BLEBLOB_USE_BL616_CONTROLLER_M10
int btblecontroller_queue_new(uint32_t size, uint32_t max_msg, void **queue_out)
#else
void *btblecontroller_queue_new(uint32_t size, uint32_t max_msg, void **queue_out)
#endif
{
    void *queue = xQueueGenericCreate(size, max_msg, 0);
    bleblob_queue_new_count++;
    bleblob_queue_new_last_size = size;
    bleblob_queue_new_last_max_msg = max_msg;
    bleblob_queue_new_last_status = queue ? 0 : 0xffffffffu;
    if (queue_out) {
        *queue_out = queue;
    }
#ifdef BL808_BLEBLOB_USE_BL616_CONTROLLER_M10
    return queue ? 0 : -1;
#else
    return queue;
#endif
}

void btblecontroller_queue_free(void *q)
{
    vQueueDelete(q);
}

int btblecontroller_queue_send(void *q, void *msg, uint32_t size, uint32_t timeout)
{
    (void)size;
    return xQueueGenericSend(q, msg, timeout, 0);
}

int btblecontroller_queue_recv(void *q, void *msg, uint32_t timeout)
{
    return xQueueReceive(q, msg, timeout);
}

int btblecontroller_queue_send_fromisr(void *q, void *msg, uint32_t size)
{
    (void)size;
    uint32_t woken = 0;
    return xQueueGenericSendFromISR(q, msg, &woken, 0);
}

int btblecontroller_queue_send_from_isr(void *q, void *msg, uint32_t size)
{
    return btblecontroller_queue_send_fromisr(q, msg, size);
}

int btblecontroller_task_new(void (*task)(void *), const char *name, int stack_size,
                             void *arg, int prio, void *task_handler)
{
    return xTaskCreate(task, name, (uint32_t)stack_size, arg, (uint32_t)prio,
                       (void **)task_handler);
}

void btblecontroller_task_delete(uint32_t task_handler)
{
    vTaskDelete((void *)task_handler);
}

int btblecontroller_xPortIsInsideInterrupt(void)
{
    return 0;
}

int btblecontroller_xport_is_inside_interrupt(void)
{
    return btblecontroller_xPortIsInsideInterrupt();
}

void btblecontroller_TaskDelay(uint32_t ms)
{
    BL602_Delay_MS(ms);
}

void btblecontroller_task_delay(uint32_t ms)
{
    btblecontroller_TaskDelay(ms);
}

void *btblecontroller_task_get_current_task_handle(void)
{
    return &bleblob_task_handle_storage;
}

void *btblecontroller_malloc(uint32_t size)
{
    return malloc((size_t)size);
}

void btblecontroller_free(void *ptr)
{
    free(ptr);
}

void btblecontroller_ble_irq_init(void *handler)
{
    bleblob_ble_irq_handler = (void (*)(void))handler;
    bleblob_ble_irq_enabled = handler != 0;
}

void btblecontroller_dm_irq_init(void *handler)
{
    bleblob_dm_irq_handler = (void (*)(void))handler;
    bleblob_dm_irq_enabled = handler != 0;
}

void btblecontroller_bt_irq_init(void *handler)
{
    (void)handler;
}

void btblecontroller_ble_irq_enable(uint8_t enable)
{
    bleblob_ble_irq_enabled = enable != 0;
}

void btblecontroller_dm_irq_enable(uint8_t enable)
{
    bleblob_dm_irq_enabled = enable != 0;
}

void btblecontroller_bt_irq_enable(uint8_t enable)
{
    (void)enable;
}

void btblecontroller_enable_ble_clk(uint8_t enable)
{
    if (enable) {
        bleblob_enable_wireless_clocks();
    }
}

void btblecontroller_rf_restore(void)
{
    bleblob_enable_wireless_clocks();
}

int btblecontroller_efuse_read_mac(uint8_t mac[6])
{
    mac[0] = 0xC0;
    mac[1] = 0x08;
    mac[2] = 0x08;
    mac[3] = 0x03;
    mac[4] = 0x04;
    mac[5] = 0x05;
    return 0;
}

void btblecontroller_software_btdm_reset(void)
{
    bb_sw_reset_cfg0(8);
    bb_sw_reset_cfg0(10);
    bleblob_enable_wireless_clocks();
}

void btblecontroller_software_pds_reset(void)
{
}

void btblecontroller_sys_reset(void)
{
    btblecontroller_software_btdm_reset();
}

void btblecontroller_pds_trim_rc32m(void)
{
}

void PDS_Trim_RC32M(void)
{
    btblecontroller_pds_trim_rc32m();
}

uint32_t btblecontrolller_get_chip_version(void)
{
    return 0;
}

void btble_uart_init(void)
{
}

void btble_uart_read(uint8_t *buf, uint32_t len)
{
    (void)buf;
    (void)len;
}

void btble_uart_write(const uint8_t *buf, uint32_t len)
{
    (void)buf;
    (void)len;
}

void btble_uart_flow_on(void)
{
}

void btble_uart_flow_off(void)
{
}

void btble_uart_finish_transfers(void)
{
}

void flash_init(void)
{
}

int flash_identify(uint8_t *pid)
{
    if (pid) {
        pid[0] = 0;
        pid[1] = 0;
        pid[2] = 0;
    }
    return 0;
}

int flash_read(uint32_t addr, uint8_t *data, uint32_t len)
{
    (void)addr;
    if (data) {
        for (uint32_t i = 0; i < len; i++) {
            data[i] = 0xff;
        }
    }
    return 0;
}

int flash_write(uint32_t addr, const uint8_t *data, uint32_t len)
{
    (void)addr;
    (void)data;
    (void)len;
    return 0;
}

int flash_erase(uint32_t addr, uint32_t len)
{
    (void)addr;
    (void)len;
    return 0;
}
#endif

void bflb_irq_attach(int irq, void (*handler)(int, void *), void *arg)
{
    (void)irq;
    (void)handler;
    (void)arg;
}

void bflb_irq_enable(int irq)
{
    (void)irq;
}

void bflb_irq_disable(int irq)
{
    (void)irq;
}

void bflb_irq_clear_pending(int irq)
{
    (void)irq;
}

int mfg_media_read_macaddr_with_lock(uint8_t mac[6], uint8_t reload)
{
    (void)reload;
    mac[0] = 0xC0;
    mac[1] = 0x01;
    mac[2] = 0x02;
    mac[3] = 0x03;
    mac[4] = 0x04;
    mac[5] = 0x05;
    return 0;
}

#ifdef BL808_BLEBLOB_USE_BL616_PHYRF
extern void phy_init(const void *config);
extern void rf_init(uint32_t xtalfreq_hz);
extern void rf_set_channel(uint8_t bandwidth, uint16_t channel_freq);
extern int8_t wl_init(void);
extern void *wl_cfg_get(uint8_t *rmem);
extern int8_t wl_ble_power_cfg_get(uint8_t phyrate);
extern void wl_bz_rx_optimize(uint16_t channel_freq);
extern void wl_bz_rx_optimize_restore(void);
extern void wl_rf_set_bz_target_power_table(int8_t target_pwr_dbm);
extern void wl_rf_set_bz_channel_pwr_comp(void);

static uint8_t bleblob_wl_rmem[1024] __attribute__((aligned(4)));
static int bleblob_rf_ready;
static int8_t bleblob_tx_power_dbm = 4;

static void bleblob_configure_wl(uint32_t xtalfreq_hz)
{
    uint8_t *cfg = (uint8_t *)wl_cfg_get(bleblob_wl_rmem);
    if (!cfg) {
        return;
    }
    *(uint32_t *)(cfg + 0) = 0;            /* status */
    cfg[4] = 2;                            /* WL_API_MODE_BZ */
    cfg[5] = 0;                            /* en_param_load */
    cfg[6] = bleblob_rf_ready ? 0 : 1;      /* en_full_cal */
    cfg[7] = 0;                            /* en_capcode_set */
    *(uint32_t *)(cfg + 8) = xtalfreq_hz;  /* param.xtalfreq_hz */
    *(void **)(cfg + 484) = 0;             /* param_load */
    *(void **)(cfg + 488) = 0;             /* capcode_set */
    *(void **)(cfg + 492) = 0;             /* capcode_get */
    *(void **)(cfg + 496) = 0;             /* log_printf */
    cfg[500] = 0;                          /* log_level */
    cfg[501] = 0;                          /* device_info */
}

void rfc_init(uint32_t xtalfreq)
{
    bleblob_prepare_wireless_domain();
    bleblob_configure_wl(xtalfreq);
    (void)wl_init();
    phy_init(0);
    rf_init(xtalfreq);
    wl_rf_set_bz_target_power_table(bleblob_tx_power_dbm);
    wl_rf_set_bz_channel_pwr_comp();
    wl_bz_rx_optimize(2402);
    rf_set_channel(0, 2402);
    bleblob_rf_ready = 1;
}

int rfc_config_power_ble(int32_t pwr_dbm)
{
    bleblob_tx_power_dbm = (int8_t)pwr_dbm;
    wl_rf_set_bz_target_power_table(bleblob_tx_power_dbm);
    wl_rf_set_bz_channel_pwr_comp();
    int8_t cfg = wl_ble_power_cfg_get(1);
    return cfg == 0 ? 1 : cfg;
}

void bz_phy_reset(void)
{
    if (bleblob_rf_ready) {
        phy_init(0);
        wl_bz_rx_optimize_restore();
        wl_bz_rx_optimize(2402);
        rf_set_channel(0, 2402);
    }
}

#elif !defined(BL808_BLEBLOB_USE_BTBLE)
void rf_set_channel(uint32_t channel)
{
    (void)channel;
}

void rfc_init(uint32_t xtalfreq)
{
    (void)xtalfreq;
}

int rfc_config_power_ble(int32_t pwr_dbm)
{
    (void)pwr_dbm;
    return 1;
}

void bz_phy_reset(void)
{
}
#endif

#if !defined(BL808_BLEBLOB_USE_QCC743) && \
    !defined(BL808_BLEBLOB_USE_BL616_CONTROLLER_M10)
void AddPdiv2_256() {}
void MultiplyBigHexModP256() {}
void SubtractFromSelfBigHex256() {}
void SubtractFromSelfBigHexSign256() {}
void specialModP256() {}
#endif
