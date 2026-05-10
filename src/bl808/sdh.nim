## BL808 SDH (SD Host Controller) driver.
##
## SDH at 0x20060000 — SD/SDIO/MMC host controller.
## SDHCI-compatible register layout.
## Supports SD 3.0, SDIO, eMMC with 1-bit and 4-bit bus widths.

import mmio, memmap

# =============================================================================
# SDH register offsets (SDHCI-compatible)
# =============================================================================
const
  SdhSdmaSysAddr*   = SdhBase + 0x00'u   # SDMA system address / argument 2
  SdhBlockSize*     = SdhBase + 0x04'u   # Block size [15:0] + block count [31:16]
  SdhArgument*      = SdhBase + 0x08'u   # Command argument
  SdhTransferMode*  = SdhBase + 0x0C'u   # Transfer mode [15:0] + command [31:16]
  SdhResponse0*     = SdhBase + 0x10'u   # Response bits [31:0]
  SdhResponse1*     = SdhBase + 0x14'u   # Response bits [63:32]
  SdhResponse2*     = SdhBase + 0x18'u   # Response bits [95:64]
  SdhResponse3*     = SdhBase + 0x1C'u   # Response bits [127:96]
  SdhBufferData*    = SdhBase + 0x20'u   # Buffer data port
  SdhPresentState*  = SdhBase + 0x24'u   # Present state
  SdhHostCtrl*      = SdhBase + 0x28'u   # Host control [7:0] + power [15:8] + block gap [23:16] + wakeup [31:24]
  SdhClockCtrl*     = SdhBase + 0x2C'u   # Clock control [15:0] + timeout [23:16] + SW reset [31:24]
  SdhIntStatus*     = SdhBase + 0x30'u   # Normal interrupt status [15:0] + error [31:16]
  SdhIntEnable*     = SdhBase + 0x34'u   # Normal interrupt status enable
  SdhIntSignal*     = SdhBase + 0x38'u   # Normal interrupt signal enable
  SdhAutoCmd12Err*  = SdhBase + 0x3C'u   # Auto CMD12 error status
  SdhCapabilities*  = SdhBase + 0x40'u   # Capabilities
  SdhCapabilities2* = SdhBase + 0x44'u   # Capabilities 2
  SdhMaxCurrent*    = SdhBase + 0x48'u   # Maximum current
  SdhForceEvent*    = SdhBase + 0x50'u   # Force event
  SdhAdmaErr*       = SdhBase + 0x54'u   # ADMA error status
  SdhAdmaAddr*      = SdhBase + 0x58'u   # ADMA system address
  SdhSlotIntSts*    = SdhBase + 0xFC'u   # Slot interrupt status / host version

# =============================================================================
# Transfer mode / command fields
# =============================================================================
const
  # Transfer mode (lower 16 bits of 0x0C)
  TmDmaEn*          = 0       # DMA enable
  TmBlkCntEn*       = 1       # Block count enable
  TmAutoCmd12*      = 2       # Auto CMD12 enable
  TmAutoCmd23*      = 3       # Auto CMD23 enable
  TmDataDir*        = 4       # Data direction (1=read, 0=write)
  TmMultiBlock*     = 5       # Multi-block transfer

  # Command (upper 16 bits of 0x0C)
  CmdRespTypeShift* = 16      # Response type [17:16]
  CmdRespTypeMask*  = 0x03'u32 shl 16
  CmdCrcEn*         = 19      # CRC check enable
  CmdIdxEn*         = 20      # Index check enable
  CmdDataPresent*   = 21      # Data present
  CmdTypeShift*     = 22      # Command type [23:22]
  CmdIdxShift*      = 24      # Command index [29:24]
  CmdIdxMask*       = 0x3F'u32 shl 24

# =============================================================================
# Present state bits
# =============================================================================
const
  PsCmdInhibit*     = 0       # Command inhibit (CMD)
  PsDatInhibit*     = 1       # Command inhibit (DAT)
  PsDatActive*      = 2       # DAT line active
  PsWriteActive*    = 8       # Write transfer active
  PsReadActive*     = 9       # Read transfer active
  PsBufWriteEn*     = 10      # Buffer write enable
  PsBufReadEn*      = 11      # Buffer read enable
  PsCardInserted*   = 16      # Card inserted
  PsCardStable*     = 17      # Card state stable
  PsCardDetect*     = 18      # Card detect pin level
  PsWriteProtect*   = 19      # Write protect switch

# =============================================================================
# Interrupt status bits
# =============================================================================
const
  IntCmdComplete*   = 0       # Command complete
  IntXferComplete*  = 1       # Transfer complete
  IntBlkGap*        = 2       # Block gap event
  IntDmaInt*        = 3       # DMA interrupt
  IntBufWriteRdy*   = 4       # Buffer write ready
  IntBufReadRdy*    = 5       # Buffer read ready
  IntCardInsert*    = 6       # Card insertion
  IntCardRemove*    = 7       # Card removal
  IntCardInt*       = 8       # Card interrupt
  IntErrInt*        = 15      # Error interrupt
  IntCmdTimeout*    = 16      # Command timeout error
  IntCmdCrc*        = 17      # Command CRC error
  IntCmdEndBit*     = 18      # Command end bit error
  IntCmdIndex*      = 19      # Command index error
  IntDataTimeout*   = 20      # Data timeout error
  IntDataCrc*       = 21      # Data CRC error
  IntDataEndBit*    = 22      # Data end bit error
  IntCurrentLimit*  = 23      # Current limit error
  IntAutoCmd12*     = 24      # Auto CMD12 error
  IntAdma*          = 25      # ADMA error

# =============================================================================
# Clock control fields
# =============================================================================
const
  ClkIntClkEn*      = 0       # Internal clock enable
  ClkIntClkStable*  = 1       # Internal clock stable
  ClkSdClkEn*       = 2       # SD clock enable
  ClkFreqSelShift*  = 8       # Frequency divider [15:8]
  ClkFreqSelMask*   = 0xFF'u32 shl 8
  ClkTimeoutShift*  = 16      # Data timeout [19:16]
  ClkTimeoutMask*   = 0x0F'u32 shl 16
  ClkSwRstAll*      = 24      # Software reset all
  ClkSwRstCmd*      = 25      # Software reset CMD line
  ClkSwRstDat*      = 26      # Software reset DAT lines

# =============================================================================
# Host control fields
# =============================================================================
const
  HcLedOn*          = 0       # LED control
  HcDataWidth*      = 1       # Data width (1=4-bit, 0=1-bit)
  HcHighSpeed*      = 2       # High speed mode
  HcDmaSelShift*    = 3       # DMA select [4:3]
  Hc8BitMode*       = 5       # 8-bit data width (eMMC)
  HcBusPowerShift*  = 8       # Bus power [11:8]
  HcBusVoltShift*   = 9       # Bus voltage [11:9]

# =============================================================================
# Types
# =============================================================================
type
  SdhError* = enum
    sdhOk
    sdhTimeout
    sdhCrcError
    sdhCmdError
    sdhDataError
    sdhNoCard

  SdhBusWidth* = enum
    sdhBus1bit = 0
    sdhBus4bit = 1
    sdhBus8bit = 2

  SdhRespType* = enum
    respNone   = 0
    resp136bit = 1  # R2
    resp48bit  = 2  # R1, R3, R6, R7
    resp48busy = 3  # R1b

# =============================================================================
# SDH initialization
# =============================================================================
proc sdhReset*() =
  ## Perform a full SDH software reset.
  regSet(SdhClockCtrl, 1'u32 shl ClkSwRstAll)
  var timeout = 100_000'u32
  while (regRead(SdhClockCtrl) and (1'u32 shl ClkSwRstAll)) != 0:
    timeout.dec
    if timeout == 0: break

proc sdhInit*(): SdhError =
  ## Initialize the SD Host Controller.
  sdhReset()

  # Enable internal clock
  regSet(SdhClockCtrl, 1'u32 shl ClkIntClkEn)
  var timeout = 100_000'u32
  while (regRead(SdhClockCtrl) and (1'u32 shl ClkIntClkStable)) == 0:
    timeout.dec
    if timeout == 0: return sdhTimeout

  # Set clock divider (start slow: 400 kHz for card init)
  regModify(SdhClockCtrl, ClkFreqSelMask, 128'u32 shl ClkFreqSelShift)

  # Enable SD clock
  regSet(SdhClockCtrl, 1'u32 shl ClkSdClkEn)

  # Set timeout
  regModify(SdhClockCtrl, ClkTimeoutMask, 0x0E'u32 shl ClkTimeoutShift)

  # Enable bus power (3.3V)
  regModify(SdhHostCtrl, 0x0F'u32 shl HcBusPowerShift,
            (1'u32 shl HcBusPowerShift) or (7'u32 shl HcBusVoltShift))

  # Clear all interrupts
  regWrite(SdhIntStatus, 0xFFFF_FFFF'u32)

  # Enable all normal + error interrupts
  regWrite(SdhIntEnable, 0x0FFF_00FF'u32)

  sdhOk

# =============================================================================
# Card detection
# =============================================================================
proc sdhCardInserted*(): bool =
  (regRead(SdhPresentState) and (1'u32 shl PsCardInserted)) != 0

proc sdhCardStable*(): bool =
  (regRead(SdhPresentState) and (1'u32 shl PsCardStable)) != 0

# =============================================================================
# Command execution
# =============================================================================
proc sdhSendCommand*(cmdIndex: uint32, argument: uint32,
                     respType: SdhRespType, dataPresent: bool = false,
                     transferMode: uint16 = 0, crcCheck: bool = true,
                     timeout: uint32 = 1_000_000): SdhError =
  ## Send an SD command and wait for completion.

  # Wait for CMD line not busy
  var countdown = timeout
  while (regRead(SdhPresentState) and (1'u32 shl PsCmdInhibit)) != 0:
    countdown.dec
    if countdown == 0: return sdhTimeout

  # Set argument
  regWrite(SdhArgument, argument)

  # Build command register value
  var cmd = transferMode.uint32 or
            (cmdIndex shl CmdIdxShift) or
            (respType.uint32 shl CmdRespTypeShift)
  if crcCheck and (respType == resp48bit or respType == resp48busy):
    # Enable CRC and index check for R1/R6/R7 responses.
    # R3 (OCR) has no CRC or index check, so callers pass crcCheck = false.
    cmd = cmd or (1'u32 shl CmdCrcEn) or (1'u32 shl CmdIdxEn)
  elif crcCheck and respType == resp136bit:
    cmd = cmd or (1'u32 shl CmdCrcEn)  # R2 has CRC but no index
  if dataPresent:
    cmd = cmd or (1'u32 shl CmdDataPresent)

  # Send command
  regWrite(SdhTransferMode, cmd)

  # Wait for command complete
  countdown = timeout
  while countdown > 0:
    let sts = regRead(SdhIntStatus)
    if (sts and (1'u32 shl IntCmdComplete)) != 0:
      regWrite(SdhIntStatus, 1'u32 shl IntCmdComplete)
      if (sts and (1'u32 shl IntErrInt)) != 0:
        regWrite(SdhIntStatus, 0xFFFF_0000'u32)
        return sdhCmdError
      return sdhOk
    countdown.dec

  sdhTimeout

proc sdhReadResponse*(resp: var array[4, uint32]) =
  ## Read the 128-bit response (for R2 commands).
  resp[0] = regRead(SdhResponse0)
  resp[1] = regRead(SdhResponse1)
  resp[2] = regRead(SdhResponse2)
  resp[3] = regRead(SdhResponse3)

proc sdhReadResponse32*(): uint32 =
  ## Read the 32-bit response (for R1/R3/R6/R7 commands).
  regRead(SdhResponse0)

# =============================================================================
# Bus configuration
# =============================================================================
proc sdhSetBusWidth*(width: SdhBusWidth) =
  case width
  of sdhBus1bit:
    regClear(SdhHostCtrl, (1'u32 shl HcDataWidth) or (1'u32 shl Hc8BitMode))
  of sdhBus4bit:
    regSet(SdhHostCtrl, 1'u32 shl HcDataWidth)
    regClear(SdhHostCtrl, 1'u32 shl Hc8BitMode)
  of sdhBus8bit:
    regSet(SdhHostCtrl, 1'u32 shl Hc8BitMode)

proc sdhSetHighSpeed*(enable: bool) =
  if enable:
    regSet(SdhHostCtrl, 1'u32 shl HcHighSpeed)
  else:
    regClear(SdhHostCtrl, 1'u32 shl HcHighSpeed)

proc sdhSetClockDiv*(divider: uint32) =
  ## Set SD clock divider (0=base clock, 1=/2, 2=/4, etc.).
  regClear(SdhClockCtrl, 1'u32 shl ClkSdClkEn)
  regModify(SdhClockCtrl, ClkFreqSelMask, (divider and 0xFF) shl ClkFreqSelShift)
  regSet(SdhClockCtrl, 1'u32 shl ClkSdClkEn)

# =============================================================================
# Data transfer (PIO)
# =============================================================================
proc sdhReadBlock*(buf: var openArray[uint32], timeout: uint32 = 1_000_000): SdhError =
  ## Read a block of data via PIO.
  var countdown = timeout
  while (regRead(SdhPresentState) and (1'u32 shl PsBufReadEn)) == 0:
    countdown.dec
    if countdown == 0: return sdhTimeout

  for i in 0 ..< buf.len:
    buf[i] = regRead(SdhBufferData)
  sdhOk

proc sdhWriteBlock*(buf: openArray[uint32], timeout: uint32 = 1_000_000): SdhError =
  ## Write a block of data via PIO.
  var countdown = timeout
  while (regRead(SdhPresentState) and (1'u32 shl PsBufWriteEn)) == 0:
    countdown.dec
    if countdown == 0: return sdhTimeout

  for word in buf:
    regWrite(SdhBufferData, word)
  sdhOk
