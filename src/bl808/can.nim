## BL808 ISO 11898 (CAN bus) controller driver.
##
## CAN at 0x2000AA00 -- ISO 11898 compatible controller.
## Shares GPIO pin function with UART2.
## Supports standard (11-bit) and extended (29-bit) identifiers,
## data frames up to 8 bytes, and basic filtering.

import mmio, memmap

# =============================================================================
# CAN register offsets (base = Uart2Base = 0x2000AA00)
# =============================================================================
const
  CanBase*          = Uart2Base

  CanModReg*        = CanBase + 0x00'u   # Mode register
  CanCmdReg*        = CanBase + 0x04'u   # Command register
  CanStsReg*        = CanBase + 0x08'u   # Status register
  CanIntSts*        = CanBase + 0x0C'u   # Interrupt status
  CanIntEn*         = CanBase + 0x10'u   # Interrupt enable
  CanBtr0*          = CanBase + 0x18'u   # Bus timing register 0
  CanBtr1*          = CanBase + 0x1C'u   # Bus timing register 1
  CanArbLostCap*    = CanBase + 0x2C'u   # Arbitration lost capture
  CanErrCode*       = CanBase + 0x30'u   # Error code capture
  CanEwlReg*        = CanBase + 0x34'u   # Error warning limit
  CanRxErrCnt*      = CanBase + 0x38'u   # RX error counter
  CanTxErrCnt*      = CanBase + 0x3C'u   # TX error counter
  CanTxBuf0*        = CanBase + 0x40'u   # TX frame info / ID / data
  CanTxBuf1*        = CanBase + 0x44'u   # TX buffer 1
  CanTxBuf2*        = CanBase + 0x48'u   # TX buffer 2
  CanTxBuf3*        = CanBase + 0x4C'u   # TX buffer 3
  CanRxBuf0*        = CanBase + 0x40'u   # RX frame info / ID / data (same offset, mode-dependent)
  CanRxBuf1*        = CanBase + 0x44'u   # RX buffer 1
  CanRxBuf2*        = CanBase + 0x48'u   # RX buffer 2
  CanRxBuf3*        = CanBase + 0x4C'u   # RX buffer 3
  CanAccCode0*      = CanBase + 0x40'u   # Acceptance code 0 (reset mode)
  CanAccCode1*      = CanBase + 0x44'u   # Acceptance code 1
  CanAccCode2*      = CanBase + 0x48'u   # Acceptance code 2
  CanAccCode3*      = CanBase + 0x4C'u   # Acceptance code 3
  CanAccMask0*      = CanBase + 0x50'u   # Acceptance mask 0 (reset mode)
  CanAccMask1*      = CanBase + 0x54'u   # Acceptance mask 1
  CanAccMask2*      = CanBase + 0x58'u   # Acceptance mask 2
  CanAccMask3*      = CanBase + 0x5C'u   # Acceptance mask 3
  CanRxMsgCnt*      = CanBase + 0x74'u   # RX message counter
  CanClockDiv*      = CanBase + 0x7C'u   # Clock divider

# =============================================================================
# Mode register fields
# =============================================================================
const
  CanResetMode*     = 0       # Reset mode (1=config, 0=operating)
  CanListenOnly*    = 1       # Listen-only mode
  CanSelfTest*      = 2       # Self-test mode
  CanAccFilter*     = 3       # Acceptance filter mode (0=dual, 1=single)

# =============================================================================
# Command register fields
# =============================================================================
const
  CanTxReq*         = 0       # Transmit request
  CanAbortTx*       = 1       # Abort transmission
  CanRelRxBuf*      = 2       # Release receive buffer
  CanClrOverrun*    = 3       # Clear data overrun
  CanSelfRxReq*     = 4       # Self-reception request (self-test)

# =============================================================================
# Status register fields
# =============================================================================
const
  CanRxBufSts*      = 0       # RX buffer status (1=msg available)
  CanDataOverrun*   = 1       # Data overrun
  CanTxBufSts*      = 2       # TX buffer status (1=released/available)
  CanTxComplete*    = 3       # Transmission complete
  CanRxStatus*      = 4       # Receiving
  CanTxStatus*      = 5       # Transmitting
  CanErrorStatus*   = 6       # Error status (error counter >= warning limit)
  CanBusOffStatus*  = 7       # Bus off

# =============================================================================
# Interrupt status / enable bits
# =============================================================================
const
  CanIntRx*         = 0       # Receive interrupt
  CanIntTx*         = 1       # Transmit interrupt
  CanIntErrWarn*    = 2       # Error warning interrupt
  CanIntDataOvr*    = 3       # Data overrun interrupt
  CanIntErrPassive* = 5       # Error passive interrupt
  CanIntArbLost*    = 6       # Arbitration lost interrupt
  CanIntBusErr*     = 7       # Bus error interrupt

# =============================================================================
# Bus timing register 0 fields
# =============================================================================
const
  CanBrpShift*      = 0       # Baud rate prescaler [5:0]
  CanBrpMask*       = 0x3F'u32
  CanSjwShift*      = 6       # Synchronization jump width [7:6]
  CanSjwMask*       = 0x03'u32 shl 6

# =============================================================================
# Bus timing register 1 fields
# =============================================================================
const
  CanTseg1Shift*    = 0       # Time segment 1 [3:0]
  CanTseg1Mask*     = 0x0F'u32
  CanTseg2Shift*    = 4       # Time segment 2 [6:4]
  CanTseg2Mask*     = 0x07'u32 shl 4
  CanSampling*      = 7       # Sampling mode (0=single, 1=triple)

# =============================================================================
# Error code capture fields
# =============================================================================
const
  CanErrSegShift*   = 0       # Error segment code [4:0]
  CanErrSegMask*    = 0x1F'u32
  CanErrDir*        = 5       # Error direction (0=TX, 1=RX)
  CanErrTypeShift*  = 6       # Error type [7:6]: 0=bit, 1=form, 2=stuff, 3=other
  CanErrTypeMask*   = 0x03'u32 shl 6

# =============================================================================
# TX/RX frame info byte fields (byte 0 of TX/RX buffer)
# =============================================================================
const
  CanFrameDlcShift* = 0       # Data length code [3:0]
  CanFrameDlcMask*  = 0x0F'u32
  CanFrameRtr*      = 6       # Remote transmission request
  CanFrameEff*      = 7       # Extended frame format (29-bit ID)

# =============================================================================
# Clock divider fields
# =============================================================================
const
  CanClkDivShift*   = 0       # Clock divider [2:0]
  CanClkDivMask*    = 0x07'u32
  CanPelicanMode*   = 7       # PeliCAN mode enable

# =============================================================================
# Types
# =============================================================================
type
  CanId* = object
    id*: uint32               # 11-bit or 29-bit identifier
    extended*: bool           # true for 29-bit extended ID

  CanFrame* = object
    id*: CanId
    dlc*: uint8               # Data length code (0-8)
    data*: array[8, uint8]    # Frame payload
    rtr*: bool                # Remote transmission request

  CanError* = enum
    canOk
    canTimeout
    canBusOff
    canOverrun
    canArbitrationLost
    canBusError

  CanBitTiming* = object
    prescaler*: uint8         # Baud rate prescaler (0-63, actual = prescaler+1)
    sjw*: uint8               # Sync jump width (0-3, actual = sjw+1)
    tseg1*: uint8             # Time segment 1 (0-15, actual = tseg1+1)
    tseg2*: uint8             # Time segment 2 (0-7, actual = tseg2+1)
    tripleSampling*: bool     # Triple sampling mode

  CanStatus* = object
    rxPending*: bool          # Message available in RX buffer
    txAvailable*: bool        # TX buffer available
    errorWarning*: bool       # Error counter >= warning limit
    busOff*: bool             # Bus off state
    dataOverrun*: bool        # Data overrun occurred
    receiving*: bool          # Currently receiving
    transmitting*: bool       # Currently transmitting

# =============================================================================
# Helper: enter/exit reset mode
# =============================================================================
proc canEnterResetMode() =
  regSet(CanModReg, 1'u32 shl CanResetMode)

proc canExitResetMode() =
  regClear(CanModReg, 1'u32 shl CanResetMode)

# =============================================================================
# CAN initialization
# =============================================================================
proc canInit*(timing: CanBitTiming, listenOnly: bool = false) =
  ## Initialize the CAN controller with given bit timing.
  ##
  ## Must configure GPIO pins for CAN function before calling.
  ## The CAN controller shares pin mux with UART2.
  ##
  ## Common bit timing for 1 Mbit/s at 40 MHz peripheral clock:
  ##   prescaler=3, sjw=1, tseg1=6, tseg2=1 (8 TQ, 75% sample point)

  # Enter reset mode for configuration
  canEnterResetMode()

  # Enable PeliCAN mode
  regSet(CanClockDiv, 1'u32 shl CanPelicanMode)

  # Set bus timing
  var btr0 = (timing.prescaler.uint32 and 0x3F) shl CanBrpShift
  btr0 = btr0 or ((timing.sjw.uint32 and 0x03) shl CanSjwShift)
  regWrite(CanBtr0, btr0)

  var btr1 = (timing.tseg1.uint32 and 0x0F) shl CanTseg1Shift
  btr1 = btr1 or ((timing.tseg2.uint32 and 0x07) shl CanTseg2Shift)
  if timing.tripleSampling:
    btr1 = btr1 or (1'u32 shl CanSampling)
  regWrite(CanBtr1, btr1)

  # Set listen-only mode if requested
  if listenOnly:
    regSet(CanModReg, 1'u32 shl CanListenOnly)
  else:
    regClear(CanModReg, 1'u32 shl CanListenOnly)

  # Default: accept all messages (mask = 0xFF = don't care)
  regWrite(CanAccCode0, 0x00'u32)
  regWrite(CanAccCode1, 0x00'u32)
  regWrite(CanAccCode2, 0x00'u32)
  regWrite(CanAccCode3, 0x00'u32)
  regWrite(CanAccMask0, 0xFF'u32)
  regWrite(CanAccMask1, 0xFF'u32)
  regWrite(CanAccMask2, 0xFF'u32)
  regWrite(CanAccMask3, 0xFF'u32)

  # Set single filter mode
  regSet(CanModReg, 1'u32 shl CanAccFilter)

  # Set default error warning limit
  regWrite(CanEwlReg, 96'u32)

# =============================================================================
# Enable / Disable
# =============================================================================
proc canEnable*() =
  ## Exit reset mode and begin CAN bus operation.
  canExitResetMode()

proc canDisable*() =
  ## Enter reset mode and halt CAN bus operation.
  canEnterResetMode()

# =============================================================================
# Status
# =============================================================================
proc canGetStatus*(): CanStatus =
  ## Read the current CAN controller status.
  let sts = regRead(CanStsReg)
  result.rxPending    = (sts and (1'u32 shl CanRxBufSts)) != 0
  result.txAvailable  = (sts and (1'u32 shl CanTxBufSts)) != 0
  result.errorWarning = (sts and (1'u32 shl CanErrorStatus)) != 0
  result.busOff       = (sts and (1'u32 shl CanBusOffStatus)) != 0
  result.dataOverrun  = (sts and (1'u32 shl CanDataOverrun)) != 0
  result.receiving    = (sts and (1'u32 shl CanRxStatus)) != 0
  result.transmitting = (sts and (1'u32 shl CanTxStatus)) != 0

proc canGetErrorCount*(): (uint32, uint32) =
  ## Returns (txErrorCount, rxErrorCount).
  let txErr = regRead(CanTxErrCnt) and 0xFF
  let rxErr = regRead(CanRxErrCnt) and 0xFF
  (txErr, rxErr)

proc canGetErrorCode*(): uint32 =
  ## Read and clear the error code capture register.
  regRead(CanErrCode)

proc canRxMessageCount*(): uint32 {.inline.} =
  ## Number of messages available in the RX buffer.
  regRead(CanRxMsgCnt) and 0x1F

# =============================================================================
# Send frame
# =============================================================================
proc canSendFrame*(frame: CanFrame, timeout: uint32 = 1_000_000): CanError =
  ## Send a CAN frame. Blocks until TX buffer is available or timeout.
  ##
  ## Returns canOk on success, canTimeout if TX buffer stays busy,
  ## or canBusOff if the controller entered bus-off state.

  # Check for bus-off
  if (regRead(CanStsReg) and (1'u32 shl CanBusOffStatus)) != 0:
    return canBusOff

  # Wait for TX buffer available
  var countdown = timeout
  while (regRead(CanStsReg) and (1'u32 shl CanTxBufSts)) == 0:
    countdown.dec
    if countdown == 0: return canTimeout

  let dlc = frame.dlc and 0x0F

  # Build frame info byte
  var info = dlc.uint32
  if frame.rtr:
    info = info or (1'u32 shl CanFrameRtr)

  if frame.id.extended:
    # Extended frame (29-bit ID)
    info = info or (1'u32 shl CanFrameEff)
    regWrite(CanTxBuf0, info)
    # ID bytes: ID[28:21], ID[20:13], ID[12:5], ID[4:0]<<3
    regWrite(CanTxBuf0 + 0x04, (frame.id.id shr 21) and 0xFF)
    regWrite(CanTxBuf0 + 0x08, (frame.id.id shr 13) and 0xFF)
    regWrite(CanTxBuf0 + 0x0C, (frame.id.id shr 5) and 0xFF)
    regWrite(CanTxBuf0 + 0x10, (frame.id.id shl 3) and 0xF8)
    # Data bytes
    for i in 0'u32 ..< dlc.uint32:
      regWrite(CanTxBuf0 + 0x14 + i * 4, frame.data[i].uint32)
  else:
    # Standard frame (11-bit ID)
    regWrite(CanTxBuf0, info)
    # ID bytes: ID[10:3], ID[2:0]<<5
    regWrite(CanTxBuf0 + 0x04, (frame.id.id shr 3) and 0xFF)
    regWrite(CanTxBuf0 + 0x08, (frame.id.id shl 5) and 0xE0)
    # Data bytes
    for i in 0'u32 ..< dlc.uint32:
      regWrite(CanTxBuf0 + 0x0C + i * 4, frame.data[i].uint32)

  # Issue transmit request
  regWrite(CanCmdReg, 1'u32 shl CanTxReq)
  canOk

# =============================================================================
# Receive frame
# =============================================================================
proc canRecvFrame*(timeout: uint32 = 1_000_000): (CanFrame, CanError) =
  ## Receive a CAN frame. Blocks until a message is available or timeout.

  var countdown = timeout
  while (regRead(CanStsReg) and (1'u32 shl CanRxBufSts)) == 0:
    countdown.dec
    if countdown == 0: return (CanFrame(), canTimeout)

  # Check for data overrun
  var err = canOk
  if (regRead(CanStsReg) and (1'u32 shl CanDataOverrun)) != 0:
    err = canOverrun
    regWrite(CanCmdReg, 1'u32 shl CanClrOverrun)

  var frame: CanFrame

  # Read frame info
  let info = regRead(CanRxBuf0)
  frame.dlc = (info and CanFrameDlcMask).uint8
  frame.rtr = (info and (1'u32 shl CanFrameRtr)) != 0

  if (info and (1'u32 shl CanFrameEff)) != 0:
    # Extended frame (29-bit ID)
    frame.id.extended = true
    let b0 = regRead(CanRxBuf0 + 0x04) and 0xFF
    let b1 = regRead(CanRxBuf0 + 0x08) and 0xFF
    let b2 = regRead(CanRxBuf0 + 0x0C) and 0xFF
    let b3 = regRead(CanRxBuf0 + 0x10) and 0xFF
    frame.id.id = (b0 shl 21) or (b1 shl 13) or (b2 shl 5) or (b3 shr 3)
    for i in 0'u32 ..< frame.dlc.uint32:
      frame.data[i] = (regRead(CanRxBuf0 + 0x14 + i * 4) and 0xFF).uint8
  else:
    # Standard frame (11-bit ID)
    frame.id.extended = false
    let b0 = regRead(CanRxBuf0 + 0x04) and 0xFF
    let b1 = regRead(CanRxBuf0 + 0x08) and 0xFF
    frame.id.id = (b0 shl 3) or (b1 shr 5)
    for i in 0'u32 ..< frame.dlc.uint32:
      frame.data[i] = (regRead(CanRxBuf0 + 0x0C + i * 4) and 0xFF).uint8

  # Release receive buffer
  regWrite(CanCmdReg, 1'u32 shl CanRelRxBuf)

  (frame, err)

# =============================================================================
# Acceptance filter
# =============================================================================
proc canSetFilter*(code0, code1, code2, code3: uint8) =
  ## Set the acceptance code registers (must be in reset mode).
  ## Call canDisable() before configuring, then canEnable() after.
  regWrite(CanAccCode0, code0.uint32)
  regWrite(CanAccCode1, code1.uint32)
  regWrite(CanAccCode2, code2.uint32)
  regWrite(CanAccCode3, code3.uint32)

proc canSetMask*(mask0, mask1, mask2, mask3: uint8) =
  ## Set the acceptance mask registers (must be in reset mode).
  ## A '1' bit in the mask means "don't care" for that bit position.
  ## Call canDisable() before configuring, then canEnable() after.
  regWrite(CanAccMask0, mask0.uint32)
  regWrite(CanAccMask1, mask1.uint32)
  regWrite(CanAccMask2, mask2.uint32)
  regWrite(CanAccMask3, mask3.uint32)

proc canSetFilterStdId*(id: uint16, mask: uint16 = 0x7FF) =
  ## Convenience: set a standard (11-bit) ID filter.
  ## Only messages matching (rxId AND mask) == (id AND mask) are accepted.
  ## Must be in reset mode (call canDisable() first).
  regSet(CanModReg, 1'u32 shl CanAccFilter)  # Single filter mode
  let code = id.uint32 shl 5
  let msk = not (mask.uint32 shl 5) and 0xFFFF
  regWrite(CanAccCode0, (code shr 8) and 0xFF)
  regWrite(CanAccCode1, code and 0xFF)
  regWrite(CanAccCode2, 0x00'u32)
  regWrite(CanAccCode3, 0x00'u32)
  regWrite(CanAccMask0, (msk shr 8) and 0xFF)
  regWrite(CanAccMask1, msk and 0xFF)
  regWrite(CanAccMask2, 0xFF'u32)
  regWrite(CanAccMask3, 0xFF'u32)

# =============================================================================
# Interrupt support
# =============================================================================
proc canEnableInterrupt*(intBit: uint32) =
  regSet(CanIntEn, 1'u32 shl intBit)

proc canDisableInterrupt*(intBit: uint32) =
  regClear(CanIntEn, 1'u32 shl intBit)

proc canReadInterruptStatus*(): uint32 =
  ## Read interrupt status (read clears the register).
  regRead(CanIntSts)

proc canEnableRxInterrupt*() =
  canEnableInterrupt(CanIntRx)

proc canEnableTxInterrupt*() =
  canEnableInterrupt(CanIntTx)

proc canEnableErrorInterrupt*() =
  canEnableInterrupt(CanIntErrWarn)
  canEnableInterrupt(CanIntBusErr)
  canEnableInterrupt(CanIntErrPassive)

proc canDisableAllInterrupts*() =
  regWrite(CanIntEn, 0x00'u32)

# =============================================================================
# Abort / Self-test
# =============================================================================
proc canAbortTransmission*() =
  ## Abort a pending transmission.
  regWrite(CanCmdReg, 1'u32 shl CanAbortTx)

proc canSelfTestSend*(frame: CanFrame): CanError =
  ## Send a frame in self-test mode (loopback, no ACK required).
  ## The controller must have been initialized with self-test mode enabled
  ## via regSet(CanModReg, 1'u32 shl CanSelfTest) while in reset mode.

  # Wait for TX buffer available
  var countdown = 100_000'u32
  while (regRead(CanStsReg) and (1'u32 shl CanTxBufSts)) == 0:
    countdown.dec
    if countdown == 0: return canTimeout

  let dlc = frame.dlc and 0x0F
  var info = dlc.uint32
  if frame.rtr:
    info = info or (1'u32 shl CanFrameRtr)

  # Standard frame only for self-test simplicity
  regWrite(CanTxBuf0, info)
  regWrite(CanTxBuf0 + 0x04, (frame.id.id shr 3) and 0xFF)
  regWrite(CanTxBuf0 + 0x08, (frame.id.id shl 5) and 0xE0)
  for i in 0'u32 ..< dlc.uint32:
    regWrite(CanTxBuf0 + 0x0C + i * 4, frame.data[i].uint32)

  # Issue self-reception request
  regWrite(CanCmdReg, 1'u32 shl CanSelfRxReq)
  canOk
