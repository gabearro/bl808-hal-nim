## BL808 MIPI CSI-2 / DSI driver.
##
## MIPI CSI at 0x3001A000 — Camera Serial Interface (2 lanes)
## MIPI DSI at 0x3001A100 — Display Serial Interface (1 lane)

import mmio, memmap

# =============================================================================
# MIPI CSI registers
# =============================================================================
const
  CsiVersion*       = MipiCsiBase + 0x00'u  # CSI version
  CsiNLanes*        = MipiCsiBase + 0x04'u  # Number of active lanes
  CsiPhyShutdown*   = MipiCsiBase + 0x08'u  # PHY shutdown control
  CsiDphyRstz*      = MipiCsiBase + 0x0C'u  # D-PHY reset control
  CsiResetN*        = MipiCsiBase + 0x10'u  # CSI-2 reset
  CsiPhyState*      = MipiCsiBase + 0x14'u  # PHY state
  CsiDataIds1*      = MipiCsiBase + 0x18'u  # Data IDs for virtual channel 0/1
  CsiDataIds2*      = MipiCsiBase + 0x1C'u  # Data IDs for virtual channel 2/3
  CsiErrInt1*       = MipiCsiBase + 0x20'u  # Error interrupt 1
  CsiErrInt2*       = MipiCsiBase + 0x24'u  # Error interrupt 2
  CsiMaskInt1*      = MipiCsiBase + 0x28'u  # Error mask 1
  CsiMaskInt2*      = MipiCsiBase + 0x2C'u  # Error mask 2
  CsiCrcRxConfig*   = MipiCsiBase + 0x30'u  # CRC/RX config
  CsiIntGenCtrl*    = MipiCsiBase + 0x34'u  # Interrupt gen control

# =============================================================================
# MIPI DSI registers
# =============================================================================
const
  DsiVersion*       = MipiDsiBase + 0x00'u  # DSI version
  DsiPwrUp*         = MipiDsiBase + 0x04'u  # Power-up control
  DsiClkMgr*        = MipiDsiBase + 0x08'u  # Clock manager
  DsiDpiCfg*        = MipiDsiBase + 0x0C'u  # DPI interface config
  DsiDbiCfg*        = MipiDsiBase + 0x10'u  # DBI interface config
  DsiPktSize*       = MipiDsiBase + 0x14'u  # Packet size
  DsiVidModeCfg*    = MipiDsiBase + 0x18'u  # Video mode config
  DsiVidPktSize*    = MipiDsiBase + 0x1C'u  # Video packet size
  DsiVidChunks*     = MipiDsiBase + 0x20'u  # Video chunks
  DsiVidNullSize*   = MipiDsiBase + 0x24'u  # Video null packet size
  DsiVidHsaTime*    = MipiDsiBase + 0x28'u  # Video HSA time
  DsiVidHbpTime*    = MipiDsiBase + 0x2C'u  # Video HBP time
  DsiVidHlineTime*  = MipiDsiBase + 0x30'u  # Video H line time
  DsiVidVsaLines*   = MipiDsiBase + 0x34'u  # Video VSA lines
  DsiVidVbpLines*   = MipiDsiBase + 0x38'u  # Video VBP lines
  DsiVidVfpLines*   = MipiDsiBase + 0x3C'u  # Video VFP lines
  DsiVidVactLines*  = MipiDsiBase + 0x40'u  # Video active lines
  DsiCmdModeCfg*    = MipiDsiBase + 0x44'u  # Command mode config
  DsiTmrLineCfg*    = MipiDsiBase + 0x48'u  # Timer line config
  DsiVtimingCfg*    = MipiDsiBase + 0x4C'u  # Vertical timing config
  DsiPhyTmrCfg*     = MipiDsiBase + 0x50'u  # PHY timing config
  DsiPhyIfCfg*      = MipiDsiBase + 0x54'u  # PHY interface config
  DsiPhyIfCtrl*     = MipiDsiBase + 0x58'u  # PHY interface control
  DsiIntSts0*       = MipiDsiBase + 0xBC'u  # Interrupt status 0
  DsiIntSts1*       = MipiDsiBase + 0xC0'u  # Interrupt status 1
  DsiIntMsk0*       = MipiDsiBase + 0xC4'u  # Interrupt mask 0
  DsiIntMsk1*       = MipiDsiBase + 0xC8'u  # Interrupt mask 1
  DsiGenHdr*        = MipiDsiBase + 0x6C'u  # Generic header
  DsiGenPayload*    = MipiDsiBase + 0x70'u  # Generic payload
  DsiCmdPktStatus*  = MipiDsiBase + 0x74'u  # Command packet status

# =============================================================================
# CSI initialization
# =============================================================================
proc csiInit*(lanes: uint32 = 2) =
  ## Initialize MIPI CSI-2 receiver.
  # Assert reset
  regWrite(CsiResetN, 0)
  regWrite(CsiDphyRstz, 0)
  regWrite(CsiPhyShutdown, 0)

  # Set number of lanes
  regWrite(CsiNLanes, lanes - 1)

  # Release PHY shutdown and reset
  regWrite(CsiPhyShutdown, 1)
  for i in 0 ..< 1000: discard regRead(CsiPhyState)
  regWrite(CsiDphyRstz, 1)

  # Release CSI reset
  regWrite(CsiResetN, 1)

  # Mask all error interrupts initially
  regWrite(CsiMaskInt1, 0xFFFF_FFFF'u32)
  regWrite(CsiMaskInt2, 0xFFFF_FFFF'u32)

proc csiGetPhyState*(): uint32 =
  regRead(CsiPhyState)

proc csiLanesActive*(): bool =
  let state = regRead(CsiPhyState)
  (state and 0x03) != 0  # Data lanes active

# =============================================================================
# DSI initialization
# =============================================================================
proc dsiInit*(lanes: uint32 = 1) =
  ## Initialize MIPI DSI transmitter.
  # Power down
  regWrite(DsiPwrUp, 0)

  # Set PHY lanes
  regWrite(DsiPhyIfCfg, lanes - 1)

  # Configure clock manager (LP clock divider)
  regWrite(DsiClkMgr, 0x0A0A'u32)  # TX/RX escape clock dividers

  # Power up
  regWrite(DsiPwrUp, 1)

proc dsiSetVideoMode*(hsaTime, hbpTime, hlineTime: uint32,
                      vsaLines, vbpLines, vfpLines, vactLines: uint32) =
  ## Configure DSI video mode timing.
  regWrite(DsiVidHsaTime, hsaTime)
  regWrite(DsiVidHbpTime, hbpTime)
  regWrite(DsiVidHlineTime, hlineTime)
  regWrite(DsiVidVsaLines, vsaLines)
  regWrite(DsiVidVbpLines, vbpLines)
  regWrite(DsiVidVfpLines, vfpLines)
  regWrite(DsiVidVactLines, vactLines)

proc dsiSendCommand*(header: uint32, payload: openArray[uint32]) =
  ## Send a DSI command packet.
  # Write payload first
  for word in payload:
    regWrite(DsiGenPayload, word)
  # Write header to trigger send
  regWrite(DsiGenHdr, header)

proc dsiCommandComplete*(): bool =
  (regRead(DsiCmdPktStatus) and 1) == 0  # CMD FIFO not full
