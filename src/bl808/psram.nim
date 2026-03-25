## BL808 PSRAM (Pseudo-SRAM) controller driver.
##
## PSRAM_CTRL at 0x20052000 — controls the external PSRAM interface.
## PSRAM_UHS at 0x3000F000 — UHS (Ultra High Speed) PSRAM controller.
##
## The Pine64 Ox64 has 64 MB pSRAM at base address 0x50000000.

import mmio, memmap

# =============================================================================
# PSRAM controller register offsets
# =============================================================================
const
  PsramCtrlCfg0*    = PsramCtrlBase + 0x00'u  # Configuration 0
  PsramCtrlCfg1*    = PsramCtrlBase + 0x04'u  # Configuration 1
  PsramCtrlCfg2*    = PsramCtrlBase + 0x08'u  # Configuration 2 (timing)
  PsramCtrlCfg3*    = PsramCtrlBase + 0x0C'u  # Configuration 3 (timing)
  PsramCtrlCfg4*    = PsramCtrlBase + 0x10'u  # Configuration 4
  PsramCtrlSts*     = PsramCtrlBase + 0x14'u  # Status
  PsramCtrlIntSts*  = PsramCtrlBase + 0x18'u  # Interrupt status
  PsramCtrlIntMask* = PsramCtrlBase + 0x1C'u  # Interrupt mask
  PsramCtrlIntClr*  = PsramCtrlBase + 0x20'u  # Interrupt clear

  # PSRAM UHS registers
  PsramUhsCfg*      = PsramUhsBase + 0x00'u  # UHS configuration
  PsramUhsTiming*   = PsramUhsBase + 0x04'u  # UHS timing
  PsramUhsStatus*   = PsramUhsBase + 0x08'u  # UHS status

# =============================================================================
# PSRAM config fields
# =============================================================================
const
  PsramEn*          = 0       # PSRAM controller enable
  PsramSizeShift*   = 4       # PSRAM size [6:4]
  PsramSizeMask*    = 0x07'u32 shl 4
  PsramBurstShift*  = 8       # Burst length [9:8]
  PsramBurstMask*   = 0x03'u32 shl 8
  PsramLatencyShift* = 12     # Read latency [14:12]
  PsramLatencyMask*  = 0x07'u32 shl 12

# =============================================================================
# Types
# =============================================================================
type
  PsramSize* = enum
    psram2mb  = 0  # 16 Mbit
    psram4mb  = 1  # 32 Mbit
    psram8mb  = 2  # 64 Mbit
    psram16mb = 3  # 128 Mbit
    psram32mb = 4  # 256 Mbit
    psram64mb = 5  # 512 Mbit

  PsramBurst* = enum
    psramBurst16 = 0
    psramBurst32 = 1
    psramBurst64 = 2
    psramBurst128 = 3

# =============================================================================
# PSRAM operations
# =============================================================================
proc psramInit*(size: PsramSize = psram64mb, burst: PsramBurst = psramBurst64) =
  ## Initialize the PSRAM controller.
  var cfg = (1'u32 shl PsramEn)
  cfg = cfg or (size.uint32 shl PsramSizeShift)
  cfg = cfg or (burst.uint32 shl PsramBurstShift)
  cfg = cfg or (3'u32 shl PsramLatencyShift)  # Default latency
  regWrite(PsramCtrlCfg0, cfg)

proc psramEnable*() =
  regSet(PsramCtrlCfg0, 1'u32 shl PsramEn)

proc psramDisable*() =
  regClear(PsramCtrlCfg0, 1'u32 shl PsramEn)

proc psramRead32*(offset: uint32): uint32 =
  ## Read a word from pSRAM via direct memory access.
  regRead(PsramBase + offset)

proc psramWrite32*(offset: uint32, value: uint32) =
  ## Write a word to pSRAM via direct memory access.
  regWrite(PsramBase + offset, value)

proc psramTestPattern*(offset: uint32 = 0): bool =
  ## Write and verify a test pattern. Returns true if pSRAM is working.
  let testAddr = PsramBase + offset
  let patterns = [0xAAAA_AAAA'u32, 0x5555_5555'u32, 0x1234_5678'u32, 0xDEAD_BEEF'u32]
  for pattern in patterns:
    regWrite(testAddr, pattern)
    if regRead(testAddr) != pattern:
      return false
  true
