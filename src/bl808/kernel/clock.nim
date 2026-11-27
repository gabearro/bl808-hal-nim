## Monotonic clock abstraction for the BL808 kernel.
##
## Provides a uniform tick-based time source across cores:
##   M0/LP: CLIC mtime (memory-mapped 64-bit counter + compare)
##   D0:    time CSR and CLINT compare
##
## Both QEMU and real hardware run mtime at 1 MHz (1 tick = 1 us).

import ../core, ../irq, ../memmap, ../mmio

# =============================================================================
# Tick rate configuration
# =============================================================================

const
  DefaultTicksPerUs* = 1'u64
    ## mtime runs at 1 MHz. Call `clockSetTickRate` at boot if needed.

  MachineTimerIrq* = 7'u32
    ## RISC-V machine timer interrupt cause code.
    ## In CLIC mode this is reported as interrupt vector 7.

var ticksPerUs: uint64 = DefaultTicksPerUs

# =============================================================================
# Tick rate
# =============================================================================

proc clockSetTickRate*(tpu: uint64) =
  ## Override the ticks-per-microsecond value.
  ## Call during init if the actual mtime frequency differs from default.
  ticksPerUs = tpu

proc clockGetTickRate*(): uint64 {.inline.} = ticksPerUs

# =============================================================================
# Tick conversions
# =============================================================================

proc usToTicks*(us: uint64): uint64 {.inline.} =
  us * ticksPerUs

proc msToTicks*(ms: uint64): uint64 {.inline.} =
  ms * 1000'u64 * ticksPerUs

proc ticksToUs*(ticks: uint64): uint64 {.inline.} =
  # BL808's 1 MHz mtime is the normal case. A 64-bit divide on M0 is a
  # software routine, and time conversion runs in the scheduler hot path.
  if ticksPerUs <= 1: ticks else: ticks div ticksPerUs

proc ticksToMs*(ticks: uint64): uint64 {.inline.} =
  ticksToUs(ticks) div 1000'u64

# kernel_read_tick_ms is defined at the bottom after readTick is available

# =============================================================================
# Platform-specific clock backend
# =============================================================================

when defined(bl808m0):
  proc readTick*(): uint64 {.inline.} =
    ## Read the current monotonic tick count from CLIC mtime.
    clicReadMtime()

  proc setDeadline*(ticks: uint64) {.inline.} =
    ## Program mtimecmp so the timer interrupt fires at `ticks`.
    clicSetMtimecmp(ticks)

  proc clearDeadline*() {.inline.} =
    ## Disable pending timer interrupt by setting mtimecmp to max.
    clicSetMtimecmp(0xFFFF_FFFF_FFFF_FFFF'u64)

  proc enableTimerIrq*() =
    ## Enable the machine timer interrupt via CLIC and mie CSR.
    clearDeadline()
    irqClearPending(MachineTimerIrq)
    irqSetLevel(MachineTimerIrq, 1)
    irqEnable(MachineTimerIrq)
    let mie = csrReadMie()
    csrWriteMie(mie or (1'u shl MachineTimerIrq))

  proc disableTimerIrq*() =
    ## Disable the machine timer interrupt.
    irqDisable(MachineTimerIrq)
    let mie = csrReadMie()
    csrWriteMie(mie and not (1'u shl MachineTimerIrq))

elif defined(bl808lp):
  # LP timer: uses addresses from memmap.nim (LpClintMtimecmpBase/LpClintMtimeBase)
  # LP CLINT at 0xE0000000 (private bus): mtimecmp at +0x4000, mtime at +0xBFF8.

  proc readTick*(): uint64 {.inline.} =
    ## A low-word rollover can occur between the two MMIO reads.
    var hi1 = regRead(LpClintMtimeBase + 4)
    var lo = regRead(LpClintMtimeBase)
    var hi2 = regRead(LpClintMtimeBase + 4)
    while hi1 != hi2:
      hi1 = hi2
      lo = regRead(LpClintMtimeBase)
      hi2 = regRead(LpClintMtimeBase + 4)
    (hi2.uint64 shl 32) or lo.uint64

  proc setDeadline*(ticks: uint64) {.inline.} =
    ## Program LP's own mtimecmp so the timer interrupt fires at `ticks`.
    regWrite(LpClintMtimecmpBase + 4, 0xFFFF_FFFF'u32)  # prevent spurious
    regWrite(LpClintMtimecmpBase, (ticks and 0xFFFF_FFFF'u64).uint32)
    regWrite(LpClintMtimecmpBase + 4, (ticks shr 32).uint32)

  proc clearDeadline*() {.inline.} =
    ## Disable pending timer interrupt by setting mtimecmp to max.
    regWrite(LpClintMtimecmpBase + 4, 0xFFFF_FFFF'u32)
    regWrite(LpClintMtimecmpBase, 0xFFFF_FFFF'u32)

  proc enableTimerIrq*() =
    ## Enable the machine timer interrupt via CLIC and mie CSR.
    clearDeadline()
    irqClearPending(MachineTimerIrq)
    irqSetLevel(MachineTimerIrq, 1)
    irqEnable(MachineTimerIrq)
    let mie = csrReadMie()
    csrWriteMie(mie or (1'u shl MachineTimerIrq))

  proc disableTimerIrq*() =
    ## Disable the machine timer interrupt.
    irqDisable(MachineTimerIrq)
    let mie = csrReadMie()
    csrWriteMie(mie and not (1'u shl MachineTimerIrq))

elif defined(bl808d0):
  import ../mmio

  # D0 CLINT at 0xE4000000 (private bus): mtimecmp at +0x4000, mtime at +0xBFF8.

  proc readTick*(): uint64 {.inline.} =
    ## Read D0 mtime via the C906 `time` CSR. The memory-mapped mtime window
    ## is only used for compare programming.
    csrReadTime().uint64

  proc setDeadline*(ticks: uint64) {.inline.} =
    ## Program D0 mtimecmp.
    regWrite(D0ClintMtimecmpBase + 4, 0xFFFF_FFFF'u32)
    regWrite(D0ClintMtimecmpBase, (ticks and 0xFFFF_FFFF'u64).uint32)
    regWrite(D0ClintMtimecmpBase + 4, (ticks shr 32).uint32)

  proc clearDeadline*() {.inline.} =
    regWrite(D0ClintMtimecmpBase + 4, 0xFFFF_FFFF'u32)
    regWrite(D0ClintMtimecmpBase, 0xFFFF_FFFF'u32)

  proc enableTimerIrq*() =
    ## Enable machine timer interrupt for D0.
    let mie = csrReadMie()
    csrWriteMie(mie or (1'u shl MachineTimerIrq))

  proc disableTimerIrq*() =
    let mie = csrReadMie()
    csrWriteMie(mie and not (1'u shl MachineTimerIrq))

# =============================================================================
# Convenience: deadline from now
# =============================================================================

proc deadlineFromNow*(us: uint64): uint64 {.inline.} =
  readTick() + usToTicks(us)

proc deadlineFromNowMs*(ms: uint64): uint64 {.inline.} =
  readTick() + msToTicks(ms)

# =============================================================================
# C-callable export for lwIP sys_arch.c
# =============================================================================

var wallClockMsHook*: proc(): uint64 {.nimcall.} = nil
  ## Optional boot-installed always-on ms source. When set (to the f32k HBN RTC
  ## via monotonicMsF32k), the ms wall clock stops depending on the CLINT mtime,
  ## which a WiFi reconnect can transiently freeze from the CPU's side. Installed
  ## by a hook (not a direct import) to avoid a clock->pds import cycle.

proc kernel_read_tick_ms*(): uint64 {.exportc, cdecl.} =
  ## ms wall clock for nowMs() and lwIP sys_now(). Uses the always-on f32k source
  ## when installed (freeze-proof); otherwise the CLINT-mtime tick.
  if wallClockMsHook != nil: wallClockMsHook()
  else: ticksToMs(readTick())
