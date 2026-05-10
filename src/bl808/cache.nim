## BL808 Cache and CCI (Cache Coherency Interface) driver.
##
## CCI at 0x20008000 — cache coherency and bus configuration.
## MCU_MISC/L1C at 0x20009000 — L1 cache control for M0 core.
##
## D0 cache is managed via T-Head CSR extensions (see core.nim).
## M0 cache is managed via the L1C registers.

import mmio, memmap, core

# =============================================================================
# CCI register offsets
# =============================================================================
const
  CciCfg*           = CciBase + 0x00'u   # CCI configuration
  CciAhbClk*        = CciBase + 0x04'u   # AHB clock configuration
  CciFlush*         = CciBase + 0x08'u   # Cache flush control
  CciAudioCfg*      = CciBase + 0x10'u   # Audio bus config
  CciCpuCfg*        = CciBase + 0x14'u   # CPU bus config

# =============================================================================
# MCU_MISC register offsets (verified from BL808 mcu_misc_reg.h)
#
# NOTE: BL808 MCU_MISC does NOT have BL602-style L1C registers at 0x00-0x20.
# Those offsets are MCU bus config on BL808. The E907 cache is controlled
# via T-Head CSR extensions (see core.nim dcacheFlushAll/icacheInvalidateAll).
# =============================================================================
const
  McuBusCfg0*       = McuMiscBase + 0x00'u  # Bus timeout config
  McuBusCfg1*       = McuMiscBase + 0x04'u  # Bus QoS config
  McuE907Rtc*       = McuMiscBase + 0x14'u  # E907 RTC config
  McuMiscCpuCfg*    = McuMiscBase + 0x100'u # CPU misc config (MCU_CFG1)
  McuLog1*          = McuMiscBase + 0x110'u # Captured mcause
  McuLog2*          = McuMiscBase + 0x114'u # Captured mintstatus
  McuLog3*          = McuMiscBase + 0x118'u # Captured mstatus
  McuLog4*          = McuMiscBase + 0x11C'u # Captured SP/PC
  McuLog5*          = McuMiscBase + 0x120'u # Lockup/halted status

# =============================================================================
# L1 cache operations (M0 core)
# =============================================================================
proc l1cInvalidateAll*(): bool =
  ## Clean and invalidate all L1 cache lines using T-Head CSR extensions.
  ## On BL808 M0 (E907), cache is controlled via custom instructions,
  ## not memory-mapped registers. See core.nim dcacheInvalidateAll().
  when defined(bl808m0) or defined(bl808d0):
    # A public whole-cache call can be reached with live call frames on the
    # cached stack. Clean first so invalidation does not discard return state.
    dcacheFlushAll()
    dcacheInvalidateAll()
    icacheInvalidateAll()
  true

proc l1cFlushAll*(): bool =
  ## Flush (clean + invalidate) all caches via T-Head extensions.
  when defined(bl808m0) or defined(bl808d0):
    dcacheFlushAll()
    icacheInvalidateAll()
  true

# =============================================================================
# CCI operations
# =============================================================================
proc cciFlushAll*() =
  ## Flush through CCI (ensures coherency across bus masters).
  regSet(CciFlush, 1'u32)
  discard regWaitClear(CciFlush, 1'u32)
