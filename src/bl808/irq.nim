## Interrupt controller drivers for BL808.
##
## D0 (C906): T-Head modified PLIC
## M0 (E907): CLIC v0.8
## LP (E902): CLIC

import mmio, memmap, core
import kernel/fault

# =============================================================================
# IRQ numbers (base offset = 16 for all cores)
# =============================================================================
const IrqBase* = 16

# M0 (E907) IRQ offsets from IrqBase
const
  IrqM0BmxBusErr*  = IrqBase + 0
  IrqM0Ipc*        = IrqBase + 3
  IrqM0Audio*      = IrqBase + 4
  IrqM0RfTop0*     = IrqBase + 5
  IrqM0RfTop1*     = IrqBase + 6
  IrqM0Lz4d*       = IrqBase + 7
  IrqM0SecEng1*    = IrqBase + 9
  IrqM0SecEng0*    = IrqBase + 10
  IrqM0SfCtrl1*    = IrqBase + 13
  IrqM0SfCtrl0*    = IrqBase + 14
  IrqM0Dma0All*    = IrqBase + 15
  IrqM0Dma1All*    = IrqBase + 16
  IrqM0Sdh*        = IrqBase + 17
  IrqM0MmAll*      = IrqBase + 18
  IrqM0IrTx*       = IrqBase + 19
  IrqM0IrRx*       = IrqBase + 20
  IrqM0Usb*        = IrqBase + 21
  IrqM0AupdmTouch* = IrqBase + 22
  IrqM0Emac*       = IrqBase + 24
  IrqM0GpadcDma*   = IrqBase + 25
  IrqM0Efuse*      = IrqBase + 26
  IrqM0Spi0*       = IrqBase + 27
  IrqM0Uart0*      = IrqBase + 28
  IrqM0Uart1*      = IrqBase + 29
  IrqM0Uart2*      = IrqBase + 30
  IrqM0GpioDma*    = IrqBase + 31
  IrqM0I2c0*       = IrqBase + 32
  IrqM0Pwm*        = IrqBase + 33
  IrqM0IpcLp*      = IrqBase + 35
  IrqM0Timer0Ch0*  = IrqBase + 36
  IrqM0Timer0Ch1*  = IrqBase + 37
  IrqM0Timer0Wdt*  = IrqBase + 38
  IrqM0I2c1*       = IrqBase + 39
  IrqM0I2s*        = IrqBase + 40
  IrqM0GpioInt0*   = IrqBase + 44
  IrqM0PdsWakeup*  = IrqBase + 50
  IrqM0HbnOut0*    = IrqBase + 51
  IrqM0HbnOut1*    = IrqBase + 52
  IrqM0Bor*        = IrqBase + 53
  IrqM0Wifi*       = IrqBase + 54
  IrqM0BzPhy*      = IrqBase + 55
  IrqM0Ble*        = IrqBase + 56
  IrqM0MacTxRxTimer* = IrqBase + 57
  IrqM0MacTxRxMisc* = IrqBase + 58
  IrqM0MacRxTrg*   = IrqBase + 59
  IrqM0MacTxTrg*   = IrqBase + 60
  IrqM0MacGen*     = IrqBase + 61
  IrqM0MacPortTrg* = IrqBase + 62
  IrqM0WifiIpcPub* = IrqBase + 63

# D0 (C906) IRQ offsets from IrqBase
const
  IrqD0BmxBusErr*  = IrqBase + 0
  IrqD0Uart3*      = IrqBase + 4
  IrqD0I2c2*       = IrqBase + 5
  IrqD0I2c3*       = IrqBase + 6
  IrqD0Spi1*       = IrqBase + 7
  IrqD0Seof0*      = IrqBase + 10
  IrqD0Seof1*      = IrqBase + 11
  IrqD0Seof2*      = IrqBase + 12
  IrqD0Dvp2bus0*   = IrqBase + 13
  IrqD0Dvp2bus1*   = IrqBase + 14
  IrqD0Dvp2bus2*   = IrqBase + 15
  IrqD0Dvp2bus3*   = IrqBase + 16
  IrqD0H264Bs*     = IrqBase + 17
  IrqD0H264Frame*  = IrqBase + 18
  IrqD0H264SeqDone* = IrqBase + 19
  IrqD0Mjpeg*      = IrqBase + 20
  IrqD0H264SBs*    = IrqBase + 21
  IrqD0H264SFrame* = IrqBase + 22
  IrqD0H264SSeqDone* = IrqBase + 23
  IrqD0Dma2Ch0*    = IrqBase + 24
  IrqD0Dma2Ch1*    = IrqBase + 25
  IrqD0Dma2Ch2*    = IrqBase + 26
  IrqD0Dma2Ch3*    = IrqBase + 27
  IrqD0Dma2Ch4*    = IrqBase + 28
  IrqD0Dma2Ch5*    = IrqBase + 29
  IrqD0Dma2Ch6*    = IrqBase + 30
  IrqD0Dma2Ch7*    = IrqBase + 31
  IrqD0SdhMmc1*    = IrqBase + 32
  IrqD0SdhMmc3*    = IrqBase + 33
  IrqD0Emac2*      = IrqBase + 36
  IrqD0MipiCsi*    = IrqBase + 37
  IrqD0Ipc*        = IrqBase + 38
  IrqD0Apu*        = IrqBase + 39
  IrqD0Mjdec*      = IrqBase + 40
  IrqD0Dvp2bus4*   = IrqBase + 41
  IrqD0Dvp2bus5*   = IrqBase + 42
  IrqD0Dvp2bus6*   = IrqBase + 43
  IrqD0Dvp2bus7*   = IrqBase + 44
  IrqD0Dma2dInt0*  = IrqBase + 45
  IrqD0Dma2dInt1*  = IrqBase + 46
  IrqD0Display*    = IrqBase + 47
  IrqD0Pwm*        = IrqBase + 48
  IrqD0Seof3*      = IrqBase + 49
  IrqD0Osd*        = IrqBase + 52
  IrqD0Dbi*        = IrqBase + 53
  IrqD0OsdaBusDrain* = IrqBase + 55
  IrqD0OsdbBusDrain* = IrqBase + 56
  IrqD0OsdPb*      = IrqBase + 57
  IrqD0MipiDsi*    = IrqBase + 59
  IrqD0Timer1Ch0*  = IrqBase + 61
  IrqD0Timer1Ch1*  = IrqBase + 62
  IrqD0Timer1Wdt*  = IrqBase + 63
  IrqD0Audio*      = IrqBase + 64
  IrqD0WlAll*      = IrqBase + 65
  IrqD0Pds*        = IrqBase + 66

# =============================================================================
# PLIC driver (for D0 / C906)
# =============================================================================
when defined(bl808d0):
  const PlicMaxIrq* = 83

  proc plicSetPriority*(irq: uint32, priority: uint32) =
    ## Set IRQ priority (0 = disabled, 1-7 = priority levels).
    if irq == 0 or irq >= PlicMaxIrq: return  # IRQ 0 has no priority register
    let offset = PlicBase + irq * 4
    regWrite(offset, priority and 0x07)

  proc plicEnableIrq*(irq: uint32) =
    ## Enable an IRQ in the PLIC (M-mode).
    let regIdx = irq div 32
    let bit = irq mod 32
    regSet(PlicEnableBase + regIdx * 4, 1'u32 shl bit)

  proc plicDisableIrq*(irq: uint32) =
    let regIdx = irq div 32
    let bit = irq mod 32
    regClear(PlicEnableBase + regIdx * 4, 1'u32 shl bit)

  proc plicEnableIrqS*(irq: uint32) =
    ## Enable an IRQ in the PLIC (S-mode).
    let regIdx = irq div 32
    let bit = irq mod 32
    regSet(PlicSEnableBase + regIdx * 4, 1'u32 shl bit)

  proc plicSetThreshold*(threshold: uint32) =
    ## Set the priority threshold (M-mode). IRQs at or below this are masked.
    regWrite(PlicThresholdM, threshold)

  proc plicSetThresholdS*(threshold: uint32) =
    regWrite(PlicThresholdS, threshold)

  proc plicClaim*(): uint32 =
    ## Claim the highest-priority pending IRQ (M-mode).
    ## Returns 0 if no IRQ pending. Note: T-Head PLIC masks the IRQ on read.
    regRead(PlicClaimM)

  proc plicClaimS*(): uint32 =
    ## Claim (S-mode).
    regRead(PlicClaimS)

  proc plicComplete*(irq: uint32) =
    ## Complete/acknowledge an IRQ (M-mode). T-Head PLIC unmasks the IRQ on write.
    regWrite(PlicClaimM, irq)

  proc plicCompleteS*(irq: uint32) =
    regWrite(PlicClaimS, irq)

  proc plicInit*() =
    ## Initialize the PLIC: disable all IRQs, set threshold to 0.
    for i in 0'u32 ..< PlicMaxIrq:
      plicSetPriority(i, 0)
    # Disable all IRQs (3 enable registers for 83 IRQs)
    regWrite(PlicEnableBase, 0)
    regWrite(PlicEnableBase + 4, 0)
    regWrite(PlicEnableBase + 8, 0)
    plicSetThreshold(0)

# =============================================================================
# CLIC driver (for M0 / E907 and LP / E902)
# =============================================================================
when defined(bl808m0) or defined(bl808lp):
  from std/volatile import volatileLoad, volatileStore

  when defined(bl808m0):
    const ClicMaxIrq* = 80
  else:
    const ClicMaxIrq* = 48

  # Per-IRQ register offsets within each 4-byte packed struct
  const
    ClicIntIp  = 0'u  # intip: interrupt pending
    ClicIntIe  = 1'u  # intie: interrupt enable
    ClicIntAttr = 2'u # intattr: trigger/mode
    ClicIntCtl = 3'u  # intctl: priority/level
    ClicIntCtlBits = 3  # BL808 implements the top 3 bits of clicintctl.

  template clicIrqAddr(irq: uint32, field: uint): uint =
    ClicIntBase + irq * ClicIntStride + field

  proc clicEnableIrq*(irq: uint32) =
    ## Enable a CLIC interrupt source.
    volatileStore(cast[ptr uint8](clicIrqAddr(irq, ClicIntIe)), 1'u8)

  proc clicDisableIrq*(irq: uint32) =
    volatileStore(cast[ptr uint8](clicIrqAddr(irq, ClicIntIe)), 0'u8)

  proc clicSetPending*(irq: uint32) =
    volatileStore(cast[ptr uint8](clicIrqAddr(irq, ClicIntIp)), 1'u8)

  proc clicClearPending*(irq: uint32) =
    volatileStore(cast[ptr uint8](clicIrqAddr(irq, ClicIntIp)), 0'u8)

  proc clicSetAttr*(irq: uint32, attr: uint8) =
    ## Set CLIC interrupt attributes.
    ##
    ## BL808 boot code may leave selective hardware vectoring enabled for some
    ## sources. The HAL uses a single software trap dispatcher, so init clears
    ## this field for every IRQ.
    volatileStore(cast[ptr uint8](clicIrqAddr(irq, ClicIntAttr)), attr)

  proc clicEncodeLevel(level: uint8): uint8 {.inline.} =
    ## Convert a logical CLIC level (0..7) into the MSB-aligned intctl field.
    if level == 0'u8:
      return 0'u8

    let maxLevel = (1'u32 shl ClicIntCtlBits) - 1'u32
    var clamped = level.uint32
    if clamped > maxLevel:
      clamped = maxLevel

    ((clamped shl (8 - ClicIntCtlBits)) and 0xFF'u32).uint8

  proc clicSetLevel*(irq: uint32, level: uint8) =
    ## Set the priority/level for a CLIC interrupt (higher = higher priority).
    volatileStore(cast[ptr uint8](clicIrqAddr(irq, ClicIntCtl)), clicEncodeLevel(level))

  proc clicReadMtime*(): uint64 =
    ## Read the CLIC machine timer (64-bit mtime).
    let lo = regRead(ClicMtimeBase)
    let hi = regRead(ClicMtimeBase + 4)
    (hi.uint64 shl 32) or lo.uint64

  proc clicSetMtimecmp*(value: uint64) =
    ## Set the machine timer compare value.
    regWrite(ClicMtimecmpBase + 4, 0xFFFF_FFFF'u32)  # prevent spurious
    regWrite(ClicMtimecmpBase, (value and 0xFFFF_FFFF'u64).uint32)
    regWrite(ClicMtimecmpBase + 4, (value shr 32).uint32)

  proc clicInit*() =
    ## Initialize CLIC: disable all interrupts.
    regWrite(ClicMintThresh, 0'u32)
    for i in 0'u32 ..< ClicMaxIrq:
      clicDisableIrq(i)
      clicClearPending(i)
      clicSetAttr(i, 0)
      clicSetLevel(i, 0)

  const IrqMExt* = 11'u32
    ## Machine external interrupt cause code.
    ## The CLIC aggregates peripheral IRQs (>=16) onto this.

  proc clicClaimPeripheral*(): uint32 =
    ## Scan CLIC pending+enabled bits to find the first active peripheral IRQ.
    ## Returns the IRQ number (>=16), or 0 if none pending.
    for i in countdown(ClicMaxIrq.int - 1, IrqBase.int):
      let ip = volatileLoad(cast[ptr uint8](clicIrqAddr(i.uint32, ClicIntIp)))
      if (ip and 1) != 0:
        let ie = volatileLoad(cast[ptr uint8](clicIrqAddr(i.uint32, ClicIntIe)))
        if (ie and 1) != 0:
          return i.uint32
    0

  proc clicCompletePeripheral*(irq: uint32) =
    ## Clear the pending bit for a peripheral IRQ after handling.
    clicClearPending(irq)

# =============================================================================
# Unified IRQ enable/disable (dispatches to CLIC or PLIC)
# =============================================================================
proc irqEnable*(irq: uint32) =
  when defined(bl808m0) or defined(bl808lp):
    clicEnableIrq(irq)
  elif defined(bl808d0):
    plicEnableIrq(irq)

proc irqDisable*(irq: uint32) =
  when defined(bl808m0) or defined(bl808lp):
    clicDisableIrq(irq)
  elif defined(bl808d0):
    plicDisableIrq(irq)

proc irqSetLevel*(irq: uint32, level: uint8) =
  when defined(bl808m0) or defined(bl808lp):
    clicSetLevel(irq, level)
  elif defined(bl808d0):
    plicSetPriority(irq, level.uint32)

proc irqClearPending*(irq: uint32) =
  when defined(bl808m0) or defined(bl808lp):
    clicClearPending(irq)
  elif defined(bl808d0):
    discard  # PLIC auto-clears on claim

# =============================================================================
# Trap handler registration
# =============================================================================
type
  TrapHandler* = proc() {.cdecl.}

when defined(bl808d0):
  const TrapHandlerCount = PlicMaxIrq
elif defined(bl808m0) or defined(bl808lp):
  const TrapHandlerCount = ClicMaxIrq
else:
  const TrapHandlerCount = 80

var trapHandlers: array[TrapHandlerCount, TrapHandler]

var
  lastTrapCause*: uint = 0
  lastTrapEpc*: uint = 0
  lastTrapValue*: uint = 0
  lastUnhandledIrq*: uint32 = 0

proc haltTrap() {.noreturn.} =
  disableInterrupts()
  while true:
    wfi()

proc registerTrapHandler*(irq: uint32, handler: TrapHandler) =
  ## Register a handler for a specific IRQ number.
  if irq < trapHandlers.len.uint32:
    trapHandlers[irq] = handler

proc bl808RegisterTrapHandlerC*(irq: uint32, handler: TrapHandler)
    {.exportc: "bl808_register_trap_handler", cdecl.} =
  registerTrapHandler(irq, handler)

proc bl808EnablePeripheralIrqC*(irq: uint32, level: uint8)
    {.exportc: "bl808_enable_peripheral_irq", cdecl.} =
  irqClearPending(irq)
  irqSetLevel(irq, level)
  irqEnable(irq)
  when defined(bl808m0) or defined(bl808lp):
    csrWriteMie(csrReadMie() or (1'u shl IrqMExt))
  enableInterrupts()

proc bl808DisablePeripheralIrqC*(irq: uint32)
    {.exportc: "bl808_disable_peripheral_irq", cdecl.} =
  irqDisable(irq)

proc getTrapHandler*(irq: uint32): TrapHandler =
  if irq < trapHandlers.len.uint32:
    trapHandlers[irq]
  else:
    nil

proc dispatchTrapInterrupt(irq: uint32): bool =
  let handler = getTrapHandler(irq)
  if handler != nil:
    handler()
    return true
  else:
    lastUnhandledIrq = irq
    return false

proc defaultTrapEntry*() {.exportc: "trap_entry", cdecl.} =
  ## Default trap entry point — dispatches to registered handlers.
  let cause = csrReadMcause()
  let isInterrupt = (cause and (1'u shl (sizeof(uint) * 8 - 1))) != 0
  let code = cause and 0xFFF

  if isInterrupt:
    when defined(bl808d0):
      if code.uint32 == 11:  # IRQ_M_EXT — external interrupt via PLIC
        let irq = plicClaim()
        if irq != 0:
          discard dispatchTrapInterrupt(irq)
          plicComplete(irq)
      else:
        # Local interrupts (timer=7, software=3) — dispatch directly
        discard dispatchTrapInterrupt(code.uint32)
    else:
      when defined(bl808m0) or defined(bl808lp):
        let irqCode = code.uint32
        if irqCode >= IrqBase:
          # CLIC mode reports the concrete interrupt vector in mcause.exccode.
          if not dispatchTrapInterrupt(irqCode):
            clicDisableIrq(irqCode)
          clicCompletePeripheral(irqCode)
        elif irqCode == IrqMExt:
          # Compatibility path for systems that aggregate peripheral IRQs.
          let irq = clicClaimPeripheral()
          if irq != 0:
            if not dispatchTrapInterrupt(irq):
              clicDisableIrq(irq)
            clicCompletePeripheral(irq)
        else:
          # Standard local interrupt (timer=7, software=3)
          discard dispatchTrapInterrupt(irqCode)
      else:
        discard dispatchTrapInterrupt(code.uint32)
  else:
    lastTrapCause = cause
    lastTrapEpc = csrReadMepc()
    lastTrapValue = csrReadMtval()
    faultHandleTrap(cause, lastTrapEpc, lastTrapValue)
    haltTrap()
