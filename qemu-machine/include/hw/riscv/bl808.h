/*
 * QEMU BL808 SoC and Machine definitions
 *
 * Bouffalo Lab BL808 -- Triple-core RISC-V SoC:
 *   M0: T-Head E907 (RV32IMAFC, 320 MHz) with CLIC
 *   D0: T-Head C906 (RV64IMAFDC, 480 MHz) with PLIC
 *   LP: T-Head E902 (RV32EMC, 150 MHz) with CLIC
 *
 * Copyright (c) 2026 BL808-HAL Project
 * SPDX-License-Identifier: GPL-2.0-or-later
 */

#ifndef HW_RISCV_BL808_H
#define HW_RISCV_BL808_H

#include <stdbool.h>

#include "hw/boards.h"
#include "hw/audio/bl808_audio.h"
#include "hw/audio/bl808_i2s.h"
#include "hw/dma/bl808_dma2d.h"
#include "hw/riscv/riscv_hart.h"
#include "hw/sysbus.h"
#include "qemu/typedefs.h"
#include "qom/object.h"

/* Peripheral model headers */
#include "hw/char/bl808_uart.h"
#include "hw/dma/bl808_dma.h"
#include "hw/i2c/bl808_i2c.h"
#include "hw/misc/bl808_cci.h"
#include "hw/misc/bl808_cks.h"
#include "hw/misc/bl808_emi.h"
#include "hw/misc/bl808_gpip.h"
#include "hw/misc/bl808_glb.h"
#include "hw/misc/bl808_ipc.h"
#include "hw/misc/bl808_mcu_misc.h"
#include "hw/misc/bl808_mm_misc.h"
#include "hw/misc/bl808_psram_ctrl.h"
#include "hw/misc/bl808_sec_eng.h"
#include "hw/misc/bl808_tzc.h"
#include "hw/misc/bl808_usb.h"
#include "hw/ssi/bl808_spi.h"
#include "hw/timer/bl808_pwm.h"
#include "hw/timer/bl808_timer.h"
#include "hw/net/bl808_emac.h"
#include "hw/sd/sdhci.h"
#include "hw/block/bl808_sf_ctrl.h"

/* ========================================================================= */
/* Memory Map                                                                 */
/* ========================================================================= */

/* MCU subsystem (M0/LP accessible) */
#define BL808_GLB_BASE          0x20000000ULL
#define BL808_GPIP_BASE         0x20002000ULL
#define BL808_SEC_ENG_BASE      0x20004000ULL
#define BL808_TZC_SEC_BASE      0x20005000ULL
#define BL808_TZC_NSEC_BASE     0x20006000ULL
#define BL808_CCI_BASE          0x20008000ULL
#define BL808_MCU_MISC_BASE     0x20009000ULL

#define BL808_UART0_BASE        0x2000A000ULL
#define BL808_UART1_BASE        0x2000A100ULL
#define BL808_SPI0_BASE         0x2000A200ULL
#define BL808_I2C0_BASE         0x2000A300ULL
#define BL808_PWM_BASE          0x2000A400ULL
#define BL808_TIMER0_BASE       0x2000A500ULL
#define BL808_IR_BASE           0x2000A600ULL
#define BL808_CKS_BASE          0x2000A700ULL
#define BL808_IPC0_BASE         0x2000A800ULL  /* M0 IPC mailbox */
#define BL808_IPC1_BASE         0x2000A840ULL  /* LP IPC mailbox */
#define BL808_I2C1_BASE         0x2000A900ULL
#define BL808_UART2_BASE        0x2000AA00ULL
#define BL808_I2S_BASE          0x2000AB00ULL
#define BL808_AUADC_BASE        0x2000AC00ULL
#define BL808_LZ4D_BASE         0x2000AD00ULL

#define BL808_SF_CTRL_BASE      0x2000B000ULL
#define BL808_DMA0_BASE         0x2000C000ULL
#define BL808_PDS_BASE          0x2000E000ULL
#define BL808_HBN_BASE          0x2000F000ULL
#define BL808_HBN_RAM_BASE      0x20010000ULL
#define BL808_HBN_RAM_SIZE      (4 * 1024)

#define BL808_EMI_MISC_BASE     0x20050000ULL
#define BL808_PSRAM_CTRL_BASE   0x20052000ULL
#define BL808_AUDIO_BASE        0x20055000ULL
#define BL808_EF_CTRL_BASE      0x20056000ULL
#define BL808_SDH_BASE          0x20060000ULL
#define BL808_EMAC_BASE         0x20070000ULL
#define BL808_DMA1_BASE         0x20071000ULL
#define BL808_USB_BASE          0x20072000ULL

/* MM subsystem (D0 accessible) */
#define BL808_MM_MISC_BASE      0x30000000ULL
#define BL808_DMA2_BASE         0x30001000ULL
#define BL808_UART3_BASE        0x30002000ULL
#define BL808_I2C2_BASE         0x30003000ULL
#define BL808_I2C3_BASE         0x30004000ULL
#define BL808_IPC2_BASE         0x30005000ULL  /* D0 IPC mailbox */
#define BL808_DMA2D_BASE        0x30006000ULL
#define BL808_MM_GLB_BASE       0x30007000ULL
#define BL808_SPI1_BASE         0x30008000ULL
#define BL808_TIMER1_BASE       0x30009000ULL
#define BL808_PSRAM_UHS_BASE    0x3000F000ULL
#define BL808_DVP0_BASE         0x30012000ULL
#define BL808_OSD_A_BASE        0x30013000ULL
#define BL808_OSD_DP_BASE       0x30015000ULL
#define BL808_DBI_BASE          0x3001B000ULL
#define BL808_CODEC_MISC_BASE   0x30020000ULL
#define BL808_MJPEG_BASE        0x30021000ULL
#define BL808_H264_BASE         0x30022000ULL
#define BL808_MJPEG_DEC_BASE    0x30023000ULL
#define BL808_BLAI_BASE         0x30024000ULL

/* RAM regions */
#define BL808_OCRAM_BASE        0x22020000ULL
#define BL808_OCRAM_CACHED      0x62020000ULL
#define BL808_OCRAM_SIZE        (64 * 1024)

#define BL808_WRAM_BASE         0x22030000ULL
#define BL808_WRAM_CACHED       0x62030000ULL
#define BL808_WRAM_SIZE         (160 * 1024)

#define BL808_DRAM_BASE         0x3EF80000ULL
#define BL808_DRAM_CACHED       0x7EF80000ULL
#define BL808_DRAM_SIZE         (512 * 1024)

#define BL808_VRAM_BASE         0x3F000000ULL
#define BL808_VRAM_CACHED       0x7F000000ULL
#define BL808_VRAM_SIZE         (32 * 1024)

#define BL808_XRAM_BASE         0x40000000ULL
#define BL808_XRAM_SIZE         (16 * 1024)

#define BL808_PSRAM_BASE        0x50000000ULL
#define BL808_PSRAM_SIZE        (64 * 1024 * 1024)

/* Flash XIP */
#define BL808_FLASH_XIP_BASE    0x58000000ULL
#define BL808_FLASH_XIP2_BASE   0x5C000000ULL
#define BL808_FLASH_REMAP_BASE  0xD8000000ULL
#define BL808_FLASH_XIP_SIZE    (64 * 1024 * 1024)

/* Boot ROM */
#define BL808_BOOTROM_BASE      0x90000000ULL
#define BL808_BOOTROM_SIZE      (128 * 1024)
#define BL808_BOOT_GPIO39_PIN   39

/* Core ID register */
#define BL808_CORE_ID_ADDR      0xF0000000ULL
#define BL808_CORE_ID_M0        0xE9070000U
#define BL808_CORE_ID_D0        0xDEAD5500U
#define BL808_CORE_ID_LP        0xDEADE902U

/* RV64 D0 firmware sign-extends many 32-bit MMIO literals above bit 31. */
#define BL808_RV64_SEXT32_BASE  0xFFFFFFFF00000000ULL
#define BL808_RV64_SEXT32(addr) (BL808_RV64_SEXT32_BASE | ((addr) & 0xFFFFFFFFULL))

/*
 * Interrupt controllers -- QEMU address mapping
 *
 * On real hardware, each BL808 core has a PRIVATE bus view of 0xE0000000:
 *
 *   M0 (hart 0): CLIC at 0xE0000000
 *     - MSIP        0xE0000000
 *     - mtimecmp    0xE0004000
 *     - mtime       0xE000BFF8
 *     - CLIC int    0xE0800000 (intip/intie/intcfg/cfg)
 *
 *   LP (hart 2): Separate CLIC instance at 0xE0000000 (same layout as M0)
 *     - MSIP        0xE0000000
 *     - mtimecmp    0xE0004000
 *     - mtime       0xE000BFF8  (shared clock, same physical counter as M0)
 *     - CLIC int    0xE0800000
 *
 *   D0 (hart 1): PLIC + CLINT at 0xE0000000
 *     - PLIC        0xE0000000  (priority/pending/enable in first 0x200000)
 *     - PLIC ctx    0xE0200000  (threshold/claim, context_base)
 *     - D0 CLINT    0xE4000000  (mtimecmp at +0x4000, mtime at +0xBFF8)
 *
 * QEMU cannot give each CPU its own address space view of 0xE0000000
 * (would require per-CPU MemoryRegion containers + cpu_address_space_init).
 * Instead, we relocate D0/LP peripherals to non-conflicting addresses:
 *
 *   M0 CLIC:    0xE0000000  (same as real hardware -- no conflict)
 *   D0 ACLINT:  0xE0100000  (replaces D0 CLINT at real 0xE4000000)
 *   LP ACLINT:  0xE0120000  (replaces LP CLIC timer at real 0xE0004000)
 *   D0 PLIC:    0xE0200000  (replaces D0 PLIC at real 0xE0000000)
 *
 * Firmware uses -d:qemu compile flag to select QEMU addresses.
 */

/*
 * Per-core private bus (0xE0000000-0xEFFFFFFF)
 *
 * On real hardware, each BL808 core has a PRIVATE bus view of this range.
 * In QEMU, we use per-CPU address spaces so each core sees its own devices:
 *
 *   M0 (hart 0):  CLINT at 0xE0000000, CLIC at 0xE0800000
 *   D0 (hart 1):  PLIC at 0xE0000000, CLINT at 0xE4000000
 *   LP (hart 2):  CLINT at 0xE0000000, CLIC at 0xE0800000
 */

/* CLINT layout (M0/LP private bus) — T-Head register layout */
#define BL808_CLINT_BASE            0xE0000000ULL
#define BL808_CLINT_SIZE            0x10000

/* CLIC interrupt control (M0/LP private bus) */
#define BL808_CLIC_BASE             0xE0800000ULL
#define BL808_CLIC_NUM_IRQS         80
#define BL808_CLIC_INTCTLBITS       3
#define BL808_LP_CLIC_NUM_IRQS      48

/* D0 PLIC (D0 private bus) */
#define BL808_D0_PLIC_BASE          0xE0000000ULL
#define BL808_D0_PLIC_SIZE          0x00400000

/* D0 CLINT (D0 private bus) */
#define BL808_D0_CLINT_BASE         0xE4000000ULL

/* LP flash XIP entry point (BL808DK CONFIG_LP_FLASH_ADDR = 0x20000) */
#define BL808_LP_FLASH_XIP_BASE     0x58020000ULL

/* IRQ counts */
#define BL808_M0_IRQ_COUNT      80
#define BL808_D0_IRQ_COUNT      83
#define BL808_LP_IRQ_COUNT      48

/* UART register offsets */
#define BL808_UART_SIZE         0x100

/* Timer register block size */
#define BL808_TIMER_SIZE        0xD0

/* IPC register block size */
#define BL808_IPC_SIZE          0x40

/* Simple register-bank stubs for modeled-but-not-functional MMIO windows */
#define BL808_REGBANK_SIZE      0x1000
#define BL808_LZ4D_SIZE         0x100

/* GPIO pin count */
#define BL808_GPIO_PINS         46
#define BL808_HBN_AON_PINS      9

/* ACLINT timer frequency (1 MHz) */
/* M0 peripheral IRQ numbers (IrqBase=16 + offset) */
#define BL808_M0_UART0_IRQ          44  /* IrqBase + 28 */
#define BL808_M0_UART1_IRQ          45  /* IrqBase + 29 */
#define BL808_M0_UART2_IRQ          46  /* IrqBase + 30 */
#define BL808_M0_SPI0_IRQ           43  /* IrqBase + 27 */
#define BL808_M0_EMAC_IRQ           40  /* IrqBase + 24 */
#define BL808_M0_DMA0_IRQ           31  /* IrqBase + 15 */
#define BL808_M0_DMA1_IRQ           32  /* IrqBase + 16 */
#define BL808_M0_SEC_ENG_ID1_IRQ    25  /* IrqBase + 9 */
#define BL808_M0_SEC_ENG_ID0_IRQ    26  /* IrqBase + 10 */
#define BL808_M0_SEC_ENG_CDET_ID1_IRQ 27 /* IrqBase + 11 */
#define BL808_M0_SEC_ENG_CDET_ID0_IRQ 28 /* IrqBase + 12 */
#define BL808_M0_IRRX_IRQ           36  /* IrqBase + 20 */
#define BL808_M0_I2C0_IRQ           48  /* IrqBase + 32 */
#define BL808_M0_PWM_IRQ            49  /* IrqBase + 33 */
#define BL808_M0_GPIO_IRQ           60  /* IrqBase + 44 */
#define BL808_M0_PDS_WAKEUP_IRQ     66  /* IrqBase + 50 */
#define BL808_M0_HBN_OUT0_IRQ       67  /* IrqBase + 51 */
#define BL808_M0_HBN_OUT1_IRQ       68  /* IrqBase + 52 */
#define BL808_M0_IPC_IRQ            19  /* IrqBase + 3 */
#define BL808_M0_USB_IRQ            37  /* IrqBase + 21 */
#define BL808_M0_TIMER0_CH0_IRQ     52  /* IrqBase + 36 */
#define BL808_M0_TIMER0_CH1_IRQ     53  /* IrqBase + 37 */
#define BL808_M0_TIMER0_WDT_IRQ     54  /* IrqBase + 38 */
#define BL808_M0_I2C1_IRQ           55  /* IrqBase + 39 */
#define BL808_M0_I2S_IRQ            56  /* IrqBase + 40 */
#define BL808_M0_WIFI_IRQ           70  /* IrqBase + 54 */
#define BL808_M0_BZ_PHY_IRQ         71  /* IrqBase + 55 */
#define BL808_M0_BLE_IRQ            72  /* IrqBase + 56 */
#define BL808_M0_WIFI_IPC_PUB_IRQ   79  /* IrqBase + 63 */
#define BL808_LP_IRRX_IRQ           36  /* IrqBase + 20 */
#define BL808_LP_IPC_IRQ            19  /* IrqBase + 3 */
#define BL808_D0_UART3_IRQ          20  /* IrqBase + 4 */
#define BL808_D0_I2C2_IRQ           21  /* IrqBase + 5 */
#define BL808_D0_I2C3_IRQ           22  /* IrqBase + 6 */
#define BL808_D0_SPI1_IRQ           23  /* IrqBase + 7 */
#define BL808_D0_DMA2_INT0_IRQ      40  /* IrqBase + 24 */
#define BL808_D0_DMA2_INT1_IRQ      41  /* IrqBase + 25 */
#define BL808_D0_DMA2_INT2_IRQ      42  /* IrqBase + 26 */
#define BL808_D0_DMA2_INT3_IRQ      43  /* IrqBase + 27 */
#define BL808_D0_DMA2_INT4_IRQ      44  /* IrqBase + 28 */
#define BL808_D0_DMA2_INT5_IRQ      45  /* IrqBase + 29 */
#define BL808_D0_DMA2_INT6_IRQ      46  /* IrqBase + 30 */
#define BL808_D0_DMA2_INT7_IRQ      47  /* IrqBase + 31 */
#define BL808_D0_EMAC2_IRQ          52  /* IrqBase + 36 */
#define BL808_D0_IPC_IRQ            54  /* IrqBase + 38 */
#define BL808_D0_DMA2D_INT0_IRQ     61  /* IrqBase + 45 */
#define BL808_D0_DMA2D_INT1_IRQ     62  /* IrqBase + 46 */
#define BL808_D0_PWM_IRQ            64  /* IrqBase + 48 */
#define BL808_D0_TIMER1_CH0_IRQ     77  /* IrqBase + 61 */
#define BL808_D0_TIMER1_CH1_IRQ     78  /* IrqBase + 62 */
#define BL808_D0_TIMER1_WDT_IRQ     79  /* IrqBase + 63 */
#define BL808_D0_AUDIO_IRQ          80  /* IrqBase + 64 */
#define BL808_D0_WL_ALL_IRQ         81  /* IrqBase + 65 */
#define BL808_D0_PDS_IRQ            82  /* IrqBase + 66 */

#define BL808_ACLINT_TIMEBASE_FREQ  1000000

/* ========================================================================= */
/* Type names                                                                 */
/* ========================================================================= */

#define TYPE_BL808_SOC      "bl808-soc"
#define TYPE_BL808_MACHINE  MACHINE_TYPE_NAME("bl808")
/* ========================================================================= */
/* SoC state                                                                  */
/* ========================================================================= */

/*
 * Forward-declare the SoC type, then use OBJECT_DECLARE_SIMPLE_TYPE
 * which creates BL808SoCStateClass and the BL808_SOC() cast macro.
 */
typedef struct BL808SoCState BL808SoCState;
OBJECT_DECLARE_SIMPLE_TYPE(BL808SoCState, BL808_SOC)

struct BL808SoCState {
    /*< private >*/
    SysBusDevice parent_obj;

    /*< public >*/
    /* CPU cores (created individually for per-CPU address spaces) */
    RISCVCPU *m0_cpu;              /* E907 RV32IMAFC, hart 0 */
    RISCVCPU *d0_cpu;              /* C906 RV64IMAFDC, hart 1 */
    RISCVCPU *lp_cpu;              /* E902 RV32EMC, hart 2 */

    /* Per-CPU address space containers */
    MemoryRegion m0_mem;           /* M0 address space container */
    MemoryRegion m0_sys_alias;     /* System memory alias for M0 */
    MemoryRegion m0_xram_alias;    /* XRAM alias for M0 (coherent I/O) */
    MemoryRegion d0_mem;           /* D0 address space container */
    MemoryRegion d0_sys_alias;     /* System memory alias for D0 */
    MemoryRegion d0_plic_sext_alias;
    MemoryRegion d0_clint_sext_alias;
    MemoryRegion d0_core_id_sext_alias;
    MemoryRegion d0_xram_alias;    /* XRAM alias for D0 (coherent I/O) */
    MemoryRegion lp_mem;           /* LP address space container */
    MemoryRegion lp_sys_alias;     /* System memory alias for LP */
    MemoryRegion lp_xram_alias;    /* XRAM alias for LP (coherent I/O) */

    /* Interrupt controllers */
    DeviceState *m0_clic;          /* M0 xt_clic */
    DeviceState *m0_clint;         /* M0 thead_clint */
    DeviceState *d0_plic;          /* D0 PLIC */
    DeviceState *lp_clic;          /* LP xt_clic */
    DeviceState *lp_clint;         /* LP thead_clint */
    DeviceState *glb;
    DeviceState *mm_glb;

    /* Peripherals */
    BL808UARTState uart[4];
    BL808I2CState i2c0;
    BL808I2CState i2c1;
    BL808I2CState i2c2;
    BL808I2CState i2c3;
    BL808SPIState spi0;
    BL808SPIState spi1;
    BL808DMAState dma0;
    BL808DMAState dma1;
    BL808DMAState dma2;
    BL808DMA2DState dma2d;
    BL808GPIPState gpip;
    BL808SecEngState sec_eng;
    BL808CCIState cci;
    BL808TZCState tzc_sec;
    BL808TZCState tzc_nsec;
    BL808MCUMiscState mcu_misc;
    BL808CKSState cks;
    BL808IPCState ipc0;
    BL808IPCState ipc1;
    BL808IPCState ipc2;
    BL808I2SState i2s;
    BL808AudioState audio;
    BL808EMIState emi;
    BL808MMMiscState mm_misc;
    BL808PSRAMCtrlState psram_ctrl;
    BL808USBState usb;
    BL808PWMState pwm;
    BL808TimerState timer0;
    BL808TimerState timer1;
    BL808EmacState emac;
    SDHCIState sdh;
    BL808SfCtrlState sf_ctrl;

    /* Memory */
    MemoryRegion ocram;
    MemoryRegion ocram_alias;      /* Cached alias */
    MemoryRegion wram;
    MemoryRegion wram_alias;
    MemoryRegion dram;
    MemoryRegion dram_alias;
    MemoryRegion vram;
    MemoryRegion vram_alias;
    MemoryRegion xram;
    MemoryRegion psram;
    uint8_t *psram_buf;
    MemoryRegion flash_xip;
    MemoryRegion flash_xip2;
    MemoryRegion flash_remap;
#ifdef TARGET_RISCV64
    MemoryRegion d0_flash_xip;
    MemoryRegion d0_flash_xip2;
    MemoryRegion d0_flash_remap;
#endif
    MemoryRegion core_id;
    bool strict_fidelity;
    bool expose_core_id_shortcut;
    bool attach_default_eeproms;
};

/* ========================================================================= */
/* Machine state                                                              */
/* ========================================================================= */

typedef struct BL808MachineState BL808MachineState;
typedef struct BL808RegBank {
    BL808MachineState *machine;
    MemoryRegion mr;
    const char *name;
    bool mm_domain;
    uint32_t regs[BL808_REGBANK_SIZE / sizeof(uint32_t)];
} BL808RegBank;

OBJECT_DECLARE_SIMPLE_TYPE(BL808MachineState, BL808_MACHINE)

struct BL808MachineState {
    /*< private >*/
    MachineState parent_obj;

    /*< public >*/
    BL808SoCState soc;
    BlockBackend *flash_blk;
    BlockBackend *sd_blk;
    MemoryRegion bootrom;
    MemoryRegion ir;
    MemoryRegion pds;
    MemoryRegion hbn;
    MemoryRegion hbn_ram;
    MemoryRegion ef_ctrl;
    MemoryRegion ble;
    MemoryRegion wifi_mac_pl;
    MemoryRegion wifi_mac_irq;
    MemoryRegion wifi_machw;
    MemoryRegion wifi_machw_intc;
    MemoryRegion wifi_ipc_emb;
    BL808RegBank lz4d;
    BL808RegBank dvp0;
    BL808RegBank osd_a;
    BL808RegBank osd_dp;
    BL808RegBank dbi;
    BL808RegBank codec_misc;
    BL808RegBank mjpeg;
    BL808RegBank h264;
    BL808RegBank mjpeg_dec;
    BL808RegBank blai;
    uint32_t ir_regs[0x100 / sizeof(uint32_t)];
    uint32_t ble_regs[0x1000 / sizeof(uint32_t)];
    uint32_t wifi_mac_pl_regs[0x1000 / sizeof(uint32_t)];
    uint32_t wifi_machw_regs[0x1000 / sizeof(uint32_t)];
    uint32_t wifi_machw_intc_regs[0x1000 / sizeof(uint32_t)];
    uint32_t wifi_ipc_status_reg;
    uint32_t wifi_ipc_enabled;
    uint32_t wifi_ipc_cfg_reg;
    uint32_t wifi_ipc_pending_status2;
    QEMUTimer *pds_wake_timer;
    QEMUTimer *pds_gpio_sample_timer;
    QEMUTimer *hbn_alarm_timer;
    QEMUTimer *hbn_alarm_rt_timer;
    QEMUTimer *hbn_gpio_sample_timer;
    QEMUTimer *hbn_gpio_delay_timer;
    uint32_t pds_regs[0x1000 / sizeof(uint32_t)];
    uint32_t hbn_regs[0x1000 / sizeof(uint32_t)];
    uint32_t ef_ctrl_regs[0x1000 / sizeof(uint32_t)];
    uint32_t efuse_data[128];
    uint32_t efuse_shadow[128];
    uint32_t timer_glb_sys_cfg0;
    uint32_t timer_glb_sys_cfg1;
    uint32_t timer_glb_dig_clk_cfg1;
    uint32_t timer_glb_wifi_pll_cfg0;
    uint32_t timer_glb_wifi_pll_cfg1;
    uint32_t timer_glb_wifi_pll_cfg5;
    uint32_t timer_glb_wifi_pll_cfg6;
    uint32_t timer_glb_wifi_pll_cfg8;
    uint32_t glb_uart_cfg0;
    uint32_t glb_i2c_cfg0;
    uint8_t timer0_bclk_div_live;
    uint32_t timer1_mm_clk_ctrl_cpu;
    uint32_t timer1_mm_clk_cpu;
    uint32_t glb_swrst_cfg2;
    uint32_t mm_sw_sys_reset;
    uint32_t mm_clk_ctrl_peri;
    uint32_t mm_clk_ctrl_peri3;
    uint64_t hbn_rtc_latch;
    uint64_t m0_entry;
    uint64_t d0_entry;
    uint64_t lp_entry;
    uint32_t irrx_inject_data;
    uint32_t irrx_inject_data1;
    uint32_t irrx_inject_bits;
    char *flash_image;
    char *bootrom_image;
    char *d0_firmware;   /* Path to D0 core (C906) firmware ELF */
    char *lp_firmware;   /* Path to LP core (E902) firmware ELF */
    char *sd_image;
    char *usb_role;
    char *camera_source;
    char *display_sink;
    char *net_phy;
    char *wifi_backend;
    char *ble_backend;
    char *zigbee_backend;
    bool boot_gpio39;
    bool strict_fidelity;
    bool expose_core_id_shortcut;
    bool attach_default_eeproms;
    bool have_m0_entry;
    bool have_d0_entry;
    bool have_lp_entry;
    bool mm_powered_on;
    bool pds_sleep_pending;
    bool glb_gpio_irq_pending;
    bool hbn_rtc_latched;
    bool hbn_wake_pending;
    bool gpio_level[BL808_GLB_GPIO_PINS];
    bool gpio_driven[BL808_GLB_GPIO_PINS];
    bool aon_gpio_level[BL808_HBN_AON_PINS];
    bool aon_gpio_driven[BL808_HBN_AON_PINS];
    bool hbn_aon_level[BL808_HBN_AON_PINS];
    bool hbn_pir_level;
    bool hbn_bod_level;
    bool hbn_acomp0_level;
    bool hbn_acomp1_level;
    uint8_t hbn_aon_history[BL808_HBN_AON_PINS];
    int64_t hbn_aon_delay_deadline_ns[BL808_HBN_AON_PINS];
    qemu_irq m0_irrx_irq;
    qemu_irq m0_pds_wakeup_irq;
    qemu_irq m0_hbn_out0_irq;
    qemu_irq m0_hbn_out1_irq;
    qemu_irq m0_wifi_irq;
    qemu_irq m0_bz_phy_irq;
    qemu_irq m0_ble_irq;
    qemu_irq m0_wifi_ipc_pub_irq;
    qemu_irq lp_irrx_irq;
    qemu_irq d0_wl_all_irq;
    qemu_irq d0_pds_irq;
    qemu_irq glb_pds_wakeup_irq;
    qemu_irq *pds_gpio_level_irqs;
    qemu_irq *hbn_aon_level_irqs;
    CPUState *pds_sleep_cpu;
    bool pds_gpio_level[32];
    uint8_t pds_gpio_history[32];
};

#endif /* HW_RISCV_BL808_H */
