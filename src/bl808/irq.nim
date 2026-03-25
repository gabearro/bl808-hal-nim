## Interrupt controller drivers for BL808.
##
## D0 (C906): T-Head modified PLIC
## M0 (E907): CLIC v0.8
## LP (E902): CLIC

import mmio, memmap, core

# =============================================================================
# IRQ numbers (base offset = 16 for all cores)
# =============================================================================
const IrqBase* = 16

# M0 (E907) IRQ offsets from IrqBase
const
  IrqM0Ipc*        = IrqBase + 3
  IrqM0Dma0All*    = IrqBase + 15
  IrqM0Dma1All*    = IrqBase + 16
  IrqM0Sdh*        = IrqBase + 17
  IrqM0Usb*        = IrqBase + 21
  IrqM0Emac*       = IrqBase + 24
  IrqM0Spi0*       = IrqBase + 27
  IrqM0Uart0*      = IrqBase + 28
  IrqM0Uart1*      = IrqBase + 29
  IrqM0Uart2*      = IrqBase + 30
  IrqM0GpioDma*    = IrqBase + 31
  IrqM0I2c0*       = IrqBase + 32
  IrqM0IpcLp*      = IrqBase + 35
  IrqM0Timer0Ch0*  = IrqBase + 36
  IrqM0Timer0Ch1*  = IrqBase + 37
  IrqM0Timer0Wdt*  = IrqBase + 38
  IrqM0I2c1*       = IrqBase + 39
  IrqM0GpioInt0*   = IrqBase + 44
  IrqM0Wifi*       = IrqBase + 54
  IrqM0Ble*        = IrqBase + 56

# D0 (C906) IRQ offsets from IrqBase
const
  IrqD0Uart3*      = IrqBase + 4
  IrqD0I2c2*       = IrqBase + 5
  IrqD0I2c3*       = IrqBase + 6
  IrqD0Spi1*       = IrqBase + 7
  IrqD0Dma2Ch0*    = IrqBase + 24
  IrqD0Dma2Ch1*    = IrqBase + 25
  IrqD0Dma2Ch2*    = IrqBase + 26
  IrqD0Dma2Ch3*    = IrqBase + 27
  IrqD0Dma2Ch4*    = IrqBase + 28
  IrqD0Dma2Ch5*    = IrqBase + 29
  IrqD0Dma2Ch6*    = IrqBase + 30
  IrqD0Dma2Ch7*    = IrqBase + 31
  IrqD0Ipc*        = IrqBase + 38
  IrqD0Pwm*        = IrqBase + 48
  IrqD0Timer1Ch0*  = IrqBase + 61
  IrqD0Timer1Ch1*  = IrqBase + 62
  IrqD0Timer1Wdt*  = IrqBase + 63

# =============================================================================
# PLIC driver (for D0 / C906)
# =============================================================================
when defined(bl808d0):
  const PlicMaxIrq* = 64

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
    # Disable all IRQs (2 enable registers for 64 IRQs)
    regWrite(PlicEnableBase, 0)
    regWrite(PlicEnableBase + 4, 0)
    plicSetThreshold(0)

# =============================================================================
# CLIC driver (for M0 / E907 and LP / E902)
# =============================================================================
when defined(bl808m0) or defined(bl808lp):
  when defined(bl808m0):
    const ClicMaxIrq* = 64
  else:
    const ClicMaxIrq* = 48

  proc clicEnableIrq*(irq: uint32) =
    ## Enable a CLIC interrupt source.
    let addr = ClicIntieBase + irq
    volatileStore(cast[ptr uint8](addr), 1'u8)

  proc clicDisableIrq*(irq: uint32) =
    let addr = ClicIntieBase + irq
    volatileStore(cast[ptr uint8](addr), 0'u8)

  proc clicSetPending*(irq: uint32) =
    let addr = ClicIntipBase + irq
    volatileStore(cast[ptr uint8](addr), 1'u8)

  proc clicClearPending*(irq: uint32) =
    let addr = ClicIntipBase + irq
    volatileStore(cast[ptr uint8](addr), 0'u8)

  proc clicSetLevel*(irq: uint32, level: uint8) =
    ## Set the priority/level for a CLIC interrupt (higher = higher priority).
    let addr = ClicIntcfgBase + irq
    volatileStore(cast[ptr uint8](addr), level)

  proc clicReadMtime*(): uint64 =
    ## Read the CLIC machine timer (64-bit mtime).
    let lo = regRead(ClicMtimeBase)
    let hi = regRead(ClicMtimeBase + 4)
    (hi.uint64 shl 32) or lo.uint64

  proc clicSetMtimecmp*(value: uint64) =
    ## Set the machine timer compare value.
    regWrite(ClicMtimecmpBase + 4, 0xFFFF_FFFF'u32)  # prevent spurious
    regWrite(ClicMtimecmpBase, (value and 0xFFFF_FFFF).uint32)
    regWrite(ClicMtimecmpBase + 4, (value shr 32).uint32)

  proc clicInit*() =
    ## Initialize CLIC: disable all interrupts.
    for i in 0'u32 ..< ClicMaxIrq:
      clicDisableIrq(i)
      clicClearPending(i)
      clicSetLevel(i, 0)

# =============================================================================
# Trap handler registration
# =============================================================================
type
  TrapHandler* = proc() {.cdecl.}

var trapHandlers: array[80, TrapHandler]

proc registerTrapHandler*(irq: uint32, handler: TrapHandler) =
  ## Register a handler for a specific IRQ number.
  if irq < trapHandlers.len.uint32:
    trapHandlers[irq] = handler

proc getTrapHandler*(irq: uint32): TrapHandler =
  if irq < trapHandlers.len.uint32:
    trapHandlers[irq]
  else:
    nil

proc defaultTrapEntry*() {.exportc: "trap_entry", cdecl.} =
  ## Default trap entry point — dispatches to registered handlers.
  let cause = csrReadMcause()
  let isInterrupt = (cause and (1'u shl (sizeof(uint) * 8 - 1))) != 0
  let code = cause and 0xFFF

  if isInterrupt:
    when defined(bl808d0):
      let irq = plicClaim()
      if irq != 0:
        let handler = getTrapHandler(irq)
        if handler != nil:
          handler()
        plicComplete(irq)
    else:
      let handler = getTrapHandler(code.uint32)
      if handler != nil:
        handler()
  # Non-interrupt traps (exceptions) — hang for now
  # In production, add fault handling here
