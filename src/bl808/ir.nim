## BL808 IR (Infrared) TX/RX driver.
##
## IR at 0x2000A600 — supports NEC, RC5, and custom IR protocols.
## Uses pulse-width modulation for TX and pulse-timing capture for RX.

import mmio, memmap

# =============================================================================
# IR register offsets
# =============================================================================
const
  # TX registers (from SDK ir_reg.h, BL808 path)
  IrTxCfg*          = IrBase + 0x00'u   # IR TX configuration
  IrTxIntSts*       = IrBase + 0x04'u   # IR TX interrupt status
  IrTxPulseWidth*   = IrBase + 0x10'u   # TX pulse width unit & modulation
  IrTxPw0*          = IrBase + 0x14'u   # Logic 0/1 pulse widths (8-bit fields)
  IrTxPw1*          = IrBase + 0x18'u   # Head/tail pulse widths (8-bit fields)

  # RX registers
  IrRxCfg*          = IrBase + 0x40'u   # IR RX configuration
  IrRxIntSts*       = IrBase + 0x44'u   # IR RX interrupt status
  IrRxPwCfg*        = IrBase + 0x48'u   # RX pulse width config (data/end threshold)
  IrRxDataCount*    = IrBase + 0x50'u   # RX data bit count
  IrRxDataWord0*    = IrBase + 0x54'u   # RX data word 0
  IrRxDataWord1*    = IrBase + 0x58'u   # RX data word 1

  # FIFO registers (BL808 uses FIFO for TX data, not direct data registers)
  IrFifoCfg0*       = IrBase + 0x80'u   # FIFO config: DMA enable, FIFO clear
  IrFifoCfg1*       = IrBase + 0x84'u   # FIFO counts and thresholds
  IrFifoWdata*      = IrBase + 0x88'u   # TX FIFO write data
  IrFifoRdata*      = IrBase + 0x8C'u   # RX FIFO read data

# =============================================================================
# IR TX configuration fields
# =============================================================================
const
  IrTxEn*           = 0       # TX enable
  IrTxModeShift*    = 2       # TX mode [3:2]: 0=NEC, 1=RC5
  IrTxModeMask*     = 0x03'u32 shl 2
  IrTxDataLenShift* = 4       # TX data length [10:4]
  IrTxDataLenMask*  = 0x7F'u32 shl 4
  IrTxHeadEn*       = 12      # Enable header pulse
  IrTxHeadOff*      = 13      # Disable header pulse
  IrTxLogic0HShift* = 16      # Logic 0 high width [19:16]
  IrTxLogic0HMask*  = 0x0F'u32 shl 16
  IrTxLogic0LShift* = 20      # Logic 0 low width [23:20]
  IrTxLogic0LMask*  = 0x0F'u32 shl 20
  IrTxLogic1HShift* = 24      # Logic 1 high width [27:24]
  IrTxLogic1HMask*  = 0x0F'u32 shl 24
  IrTxLogic1LShift* = 28      # Logic 1 low width [31:28]
  IrTxLogic1LMask*  = 0x0F'u32 shl 28

# =============================================================================
# IR RX configuration fields
# =============================================================================
const
  IrRxEn*           = 0       # RX enable
  IrRxModeShift*    = 2       # RX mode [3:2]
  IrRxModeMask*     = 0x03'u32 shl 2
  IrRxDeglitchEn*   = 4       # Deglitch enable
  IrRxDeglitchCntShift* = 8   # Deglitch count [11:8]
  IrRxDeglitchCntMask*  = 0x0F'u32 shl 8

# =============================================================================
# Types
# =============================================================================
type
  IrMode* = enum
    irNec  = 0   # NEC protocol (38 kHz carrier)
    irRc5  = 1   # RC5 protocol (36 kHz carrier)

  IrError* = enum
    irOk
    irTimeout
    irOverflow

# =============================================================================
# IR TX
# =============================================================================
proc irTxInit*(mode: IrMode = irNec) =
  ## Initialize IR transmitter.
  regClear(IrTxCfg, 1'u32 shl IrTxEn)
  regModify(IrTxCfg, IrTxModeMask, mode.uint32 shl IrTxModeShift)
  # Default NEC timing: 38 kHz carrier
  # PulseWidth: mod_ph0[23:16]=13, mod_ph1[31:24]=13 for ~38kHz, pw_unit[11:0]=1
  regWrite(IrTxPulseWidth, (13'u32 shl 16) or (13'u32 shl 24) or 1)
  # Pulse widths for NEC: logic0=560us H + 560us L, logic1=560us H + 1690us L
  regWrite(IrTxPw0, (9'u32) or (9'u32 shl 8) or (9'u32 shl 16) or (27'u32 shl 24))
  # Head: 9ms + 4.5ms, Tail: 560us
  regWrite(IrTxPw1, (144'u32) or (72'u32 shl 8) or (9'u32 shl 16))
  # Clear TX FIFO
  regSet(IrFifoCfg0, 1'u32 shl 2)

proc irTxSend*(data: uint32, bits: uint32 = 32) =
  ## Send IR data via FIFO.
  regModify(IrTxCfg, IrTxDataLenMask, ((bits - 1) and 0x7F) shl IrTxDataLenShift)
  # Write data to TX FIFO
  regWrite(IrFifoWdata, data)
  regSet(IrTxCfg, (1'u32 shl IrTxEn) or (1'u32 shl IrTxHeadEn))
  # Wait for TX complete
  var timeout = 100_000'u32
  while (regRead(IrTxIntSts) and 1) == 0:
    timeout.dec
    if timeout == 0: break
  regClear(IrTxCfg, 1'u32 shl IrTxEn)
  regWrite(IrTxIntSts, 1'u32 shl 16)  # Clear end interrupt

proc irTxSendNec*(address: uint8, command: uint8) =
  ## Send a standard NEC IR command (address + command with complements).
  let necData = address.uint32 or
                ((not address).uint32 shl 8) or
                (command.uint32 shl 16) or
                ((not command).uint32 shl 24)
  irTxSend(necData, 32)

# =============================================================================
# IR RX
# =============================================================================
proc irRxInit*(mode: IrMode = irNec) =
  ## Initialize IR receiver.
  regClear(IrRxCfg, 1'u32 shl IrRxEn)
  regModify(IrRxCfg, IrRxModeMask, mode.uint32 shl IrRxModeShift)
  # Enable deglitch
  regSet(IrRxCfg, (1'u32 shl IrRxDeglitchEn) or (3'u32 shl IrRxDeglitchCntShift))

proc irRxEnable*() =
  regSet(IrRxCfg, 1'u32 shl IrRxEn)

proc irRxDisable*() =
  regClear(IrRxCfg, 1'u32 shl IrRxEn)

proc irRxRead*(timeout: uint32 = 1_000_000): (uint32, IrError) =
  ## Read received IR data word 0. Returns (data, error).
  var countdown = timeout
  while (regRead(IrRxIntSts) and 1) == 0:
    countdown.dec
    if countdown == 0: return (0'u32, irTimeout)
  let data = regRead(IrRxDataWord0)
  regWrite(IrRxIntSts, 1'u32 shl 16)  # Clear end interrupt
  (data, irOk)

proc irRxGetBitCount*(): uint32 =
  ## Get the number of bits received.
  regRead(IrRxDataCount) and 0x7F

proc irRxFifoCount*(): uint32 =
  (regRead(IrFifoCfg1) shr 8) and 0x7F

proc irRxFifoRead*(): uint32 =
  regRead(IrFifoRdata)
