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
# L1C (L1 Cache) register offsets
# =============================================================================
const
  L1cConfig*        = McuMiscBase + 0x00'u  # L1C config
  L1cHitCnt*        = McuMiscBase + 0x04'u  # Cache hit counter
  L1cMissCnt*       = McuMiscBase + 0x08'u  # Cache miss counter
  L1cIromConfig*    = McuMiscBase + 0x10'u  # I-ROM cache config
  L1cIrom2Config*   = McuMiscBase + 0x14'u  # I-ROM2 cache config
  L1cCntCtrl*       = McuMiscBase + 0x1C'u  # Counter control
  L1cBusCfg*        = McuMiscBase + 0x20'u  # Bus error config

  # MCU misc
  McuMiscCpuCfg*    = McuMiscBase + 0x100'u # CPU misc config
  McuBusRemap*      = McuMiscBase + 0x104'u # Bus remap
  McuE907Info*      = McuMiscBase + 0x114'u # E907 core info

# =============================================================================
# L1C config fields
# =============================================================================
const
  L1cIcacheEn*      = 0       # I-cache enable
  L1cDcacheEn*      = 1       # D-cache enable
  L1cWayDisShift*   = 8       # Way disable mask [11:8]
  L1cWayDisMask*    = 0x0F'u32 shl 8
  L1cInvReq*        = 12      # Cache invalidate request
  L1cFlushReq*      = 13      # Cache flush (clean+invalidate) request
  L1cInvDone*       = 14      # Invalidate done (read-only)
  L1cFlushDone*     = 15      # Flush done (read-only)

# =============================================================================
# L1 cache operations (M0 core)
# =============================================================================
proc l1cEnableIcache*() =
  ## Enable M0 I-cache.
  regSet(L1cConfig, 1'u32 shl L1cIcacheEn)

proc l1cDisableIcache*() =
  regClear(L1cConfig, 1'u32 shl L1cIcacheEn)

proc l1cEnableDcache*() =
  ## Enable M0 D-cache.
  regSet(L1cConfig, 1'u32 shl L1cDcacheEn)

proc l1cDisableDcache*() =
  regClear(L1cConfig, 1'u32 shl L1cDcacheEn)

proc l1cInvalidateAll*(): bool =
  ## Invalidate all L1 cache lines. Returns true when done.
  regSet(L1cConfig, 1'u32 shl L1cInvReq)
  var timeout = 100_000'u32
  while (regRead(L1cConfig) and (1'u32 shl L1cInvDone)) == 0:
    timeout.dec
    if timeout == 0: return false
  regClear(L1cConfig, 1'u32 shl L1cInvReq)
  true

proc l1cFlushAll*(): bool =
  ## Flush (clean + invalidate) all L1 cache lines. Returns true when done.
  regSet(L1cConfig, 1'u32 shl L1cFlushReq)
  var timeout = 100_000'u32
  while (regRead(L1cConfig) and (1'u32 shl L1cFlushDone)) == 0:
    timeout.dec
    if timeout == 0: return false
  regClear(L1cConfig, 1'u32 shl L1cFlushReq)
  true

proc l1cGetHitCount*(): uint32 =
  regRead(L1cHitCnt)

proc l1cGetMissCount*(): uint32 =
  regRead(L1cMissCnt)

proc l1cResetCounters*() =
  regWrite(L1cCntCtrl, 1)

# =============================================================================
# CCI operations
# =============================================================================
proc cciFlushAll*() =
  ## Flush through CCI (ensures coherency across bus masters).
  regSet(CciFlush, 1'u32)
  regWaitClear(CciFlush, 1'u32)
