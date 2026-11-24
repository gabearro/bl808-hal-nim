## Diagnostic-only M0 PC sampler for the all-core AP timing bench.

import bl808/[core, irq, memmap, mmio, timer]

const
  SampleIrq = IrqM0Timer0Ch1
  SampleCap = 1024
  SamplePeriodUs {.intdefine.} = 239
  ChannelEnable = 1'u32 shl TcerTimer3En
  ChannelClear = 1'u32 shl 6
  ChannelMode = 1'u32 shl 2
  SavedRegisters = [TimerTccr, TimerTcdr, TimerTcmr, TimerTplcr3,
                    TimerTplvr3, TimerTmr3_0, TimerTmr3_1, TimerTmr3_2]

static: doAssert SamplePeriodUs in 200 .. 500

var
  # [CLIC mtime low, interrupted PC]; no call stacks or credential data.
  apPcSamples {.exportc: "allcore_ap_pc_samples", codegenDecl:
      "$# $# __attribute__((section(\".psrambss.ap_pc\"), aligned(8)))".}:
      array[SampleCap, array[2, uint32]]
  apPcStats {.exportc: "allcore_ap_pc_stats", volatile.}: array[3, uint32]
  saved: array[SavedRegisters.len, uint32]

proc samplePc() {.cdecl.} =
  let at = regRead(ClicMtimeBase)
  let pc = csrReadMepc().uint32
  regWrite(Timer0Base + TimerTicr3, 1)
  let i = apPcStats[0]
  if i < SampleCap.uint32:
    apPcSamples[i.int] = [at, pc]
    apPcStats[0] = i + 1
  else:
    inc apPcStats[1]
  apPcStats[2] += regRead(ClicMtimeBase) - at

proc startApPcProfile*(): bool =
  if getTrapHandler(SampleIrq) != nil or
      (regRead(Timer0Base + TimerTcer) and ChannelEnable) != 0 or
      (regRead(Timer0Base + TimerTier3) and 7) != 0 or
      (csrReadMstatus() and 8) == 0:
    return false
  for i, offset in SavedRegisters:
    saved[i] = regRead(Timer0Base + offset)
  apPcStats = [0'u32, 0, 0]
  let t = initTimer(timer0)
  t.setClockSource(timerCh3, timerClkXtal)
  t.setClockDiv(timerCh3, 39) # 40 MHz crystal to a nominal 1 MHz.
  regClear(Timer0Base + TimerTcmr, ChannelMode)
  regWrite(Timer0Base + TimerTplcr3, 1) # Reload on compare 0.
  t.setPreloadValue(timerCh3, 0)
  t.setMatchValue(timerCh3, 0, SamplePeriodUs.uint32)
  t.setMatchValue(timerCh3, 1, high(uint32))
  t.setMatchValue(timerCh3, 2, high(uint32))
  regSet(Timer0Base + TimerTcer, ChannelClear)
  regClear(Timer0Base + TimerTcer, ChannelClear)
  t.clearInterrupt(timerCh3, 0)
  registerTrapHandler(SampleIrq, samplePc)
  irqSetLevel(SampleIrq, 1)
  irqClearPending(SampleIrq)
  irqEnable(SampleIrq)
  t.enableInterrupt(timerCh3, 0)
  t.enable(timerCh3)
  true

proc stopApPcProfile*() =
  let t = initTimer(timer0)
  irqDisable(SampleIrq)
  t.disable(timerCh3)
  t.disableInterrupt(timerCh3, 0)
  t.clearInterrupt(timerCh3, 0)
  irqClearPending(SampleIrq)
  registerTrapHandler(SampleIrq, nil)
  regModify(Timer0Base + TimerTccr, TccrClk3SrcMask, saved[0] and TccrClk3SrcMask)
  regModify(Timer0Base + TimerTcdr, TcdrTimer3Mask, saved[1] and TcdrTimer3Mask)
  regModify(Timer0Base + TimerTcmr, ChannelMode, saved[2] and ChannelMode)
  for i in 3 ..< SavedRegisters.len:
    regWrite(Timer0Base + SavedRegisters[i], saved[i])
