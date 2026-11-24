## One-second RF SRAM power trace with an RF-gain tag per snapshot.
## The dedicated CSI linker map reserves the OCRAM dump destination.

import bl808/startup, bl808/core
import bl808/glb, bl808/gpio, bl808/uart
import bl808/mmio
import bl808/panicoverride
import bl808/kernel/alloc
import bl808/wifi
import bl808/wifi_fw
import bl808/wifi/csi_capture
from std/volatile import volatileStore

when not defined(bl808CsiCapture):
  {.error: "RF audio trace requires -d:bl808CsiCapture".}

const
  ConsoleBaud {.intdefine.} = 230_400'u32
  ConsoleClkHz {.intdefine.} = 40_000_000'u32
  CsiFrequencyMhz {.intdefine.} = 2412'u32
  TraceCount {.intdefine.} = 7200
  TraceIntervalUs = 125'u32
  CsiWords = 256'u32
  PowerSamples = 16
  CsiPollLimit = 2_000_000'u32
  RfBase = CsiRfBase
  RfPuCtrl = RfBase + 0x02C'u
  RfRxCfg = RfBase + 0x048'u
  RfAdcCfg = RfBase + 0x088'u
  RfDumpCfg = RfBase + 0x220'u
  RfForce = RfBase + 0x26C'u
  DumpSram = RfBase + 0x23C'u
  DumpCtrl = RfBase + 0x240'u
  DumpAddr = RfBase + 0x244'u
  DumpDone = 1'u32
  DumpEnable = 2'u32
  DumpClear = 8'u32
  RiuMux = 0x24900078'u
  RiuSecondDiag = 0x24C0C924'u
  RiuBank00And03 = 0x03010001'u32
  CsiPoison = 0xA5A0055A'u32

var console: Uart
var powers: array[TraceCount, uint32]
var rfGains: array[TraceCount, uint8]

proc emit(label: string; value: uint32) =
  discard console.sendString(" ")
  discard console.sendString(label)
  discard console.sendString("=")
  console.sendHex32(value)

proc main() {.exportc, cdecl.} =
  systemInit()
  heapInit()
  enablePeriphClock(periphUart0)
  setMcuXclkSource(mcuXclkXtal)
  setUartClock(true, uartClkXclk, 0)
  gpioSetupUart(14, 15)
  console = initUart(uart0, UartConfig(
    baudRate: ConsoleBaud, dataBits: data8, stopBits: stop1,
    parity: parityNone), ConsoleClkHz)
  discard console.sendLine("RF AUDIO TRACE START")
  console.flushTx()

  if CsiFrequencyMhz < 2412'u32 or CsiFrequencyMhz > 2484'u32 or
      TraceCount < 1 or TraceCount > 7200:
    discard console.sendLine("RF AUDIO TRACE INVALID")
    return

  rfc_init(40_000_000'u32)
  phySetChannel(1'u8, 0'u8, CsiFrequencyMhz.uint16,
                CsiFrequencyMhz.uint16, 0'u16, 0'u8)
  let savedForce = regRead(RfForce)
  let savedPu = regRead(RfPuCtrl)
  let savedRx = regRead(RfRxCfg)
  let savedAdc = regRead(RfAdcCfg)
  let savedDumpCfg = regRead(RfDumpCfg)
  let savedRiuMux = regRead(RiuMux)

  rfc_rf_fsm_force(3'u32)
  regWrite(RfPuCtrl, savedPu and not 2'u32)
  regWrite(RfRxCfg, (savedRx and not 0x731F'u32) or 0x311F'u32)
  regWrite(RfAdcCfg, (savedAdc and not 0x03000000'u32) or 0x03000000'u32)
  regWrite(RfDumpCfg, savedDumpCfg or 0x1E3'u32)
  let probe = csiProbeSnapshot(1'u32, CsiPollLimit)

  var completed = 0'u32
  var lateStarts = 0'u32
  var maxStartLag = 0'u32
  var engineMaxUs = 0'u32
  var failure = probe.status.uint32
  if probe.status == csiCaptured and probe.strideWords == 1'u32:
    let savedDumpSram = regRead(DumpSram)
    let savedDumpAddr = regRead(DumpAddr)
    let savedDumpCtrl = regRead(DumpCtrl)
    let idleCtrl = savedDumpCtrl and 0x0000FFF0'u32
    regWrite(RfDumpCfg, (regRead(RfDumpCfg) and not (3'u32 shl 9)) or
      (1'u32 shl 9))
    regWrite(DumpSram, savedDumpSram and not (7'u32 shl 16))
    regWrite(DumpAddr, (CsiStartIndex shl 16) or (CsiStartIndex + CsiWords))
    regWrite(RiuMux, RiuBank00And03)
    let baseTick = regRead(0xE000BFF8'u) + 250'u32
    for index in 0 ..< TraceCount:
      for position in 0 ..< 4:
        let wordIndex = (CsiWords - 1'u32) * position.uint32 div 3'u32
        volatileStore(cast[ptr uint32](CsiSampleBase + wordIndex.uint * 4'u),
          CsiPoison)
      regWrite(DumpCtrl, idleCtrl or DumpClear)
      regWrite(DumpCtrl, idleCtrl)
      let target = baseTick + index.uint32 * TraceIntervalUs
      while regRead(0xE000BFF8'u) < target:
        discard
      let started = regRead(0xE000BFF8'u)
      let lag = started - target
      if lag != 0'u32:
        inc lateStarts
        maxStartLag = max(maxStartLag, lag)
      if (regRead(DumpCtrl) and DumpDone) != 0'u32:
        failure = csiStaleDone.uint32
        break
      regWrite(DumpCtrl, idleCtrl or DumpEnable)
      var done = false
      for poll in 0'u32 ..< CsiPollLimit:
        if (regRead(DumpCtrl) and DumpDone) != 0'u32:
          done = true
          break
      let engineUs = regRead(0xE000BFF8'u) - started
      engineMaxUs = max(engineMaxUs, engineUs)
      regWrite(DumpCtrl, idleCtrl)
      if not done:
        failure = csiTimedOut.uint32
        break
      for position in 0 ..< 4:
        let wordIndex = (CsiWords - 1'u32) * position.uint32 div 3'u32
        if csiSampleWord(wordIndex) == CsiPoison:
          failure = csiNoBufferChange.uint32
      if failure != csiCaptured.uint32:
        break
      var power = 0'u32
      for sample in 0 ..< PowerSamples:
        let wordIndex = sample.uint32 * CsiWords div PowerSamples.uint32
        let word = csiSampleWord(wordIndex)
        let i = cast[int16]((word shr 16).uint16).int32 - 55'i32
        let q = cast[int16](word.uint16).int32 + 5'i32
        power += (i * i + q * q).uint32
      powers[index] = power
      # AX3000's matching RIU bank-3 map calls bits 15:8 RF gain in dB.
      rfGains[index] = ((regRead(RiuSecondDiag) shr 24) and 0xFF'u32).uint8
      inc completed
    regWrite(DumpCtrl, idleCtrl or DumpClear)
    regWrite(DumpCtrl, idleCtrl)
    regWrite(DumpAddr, savedDumpAddr)
    regWrite(DumpSram, savedDumpSram)
  else:
    failure = csiInvalidRequest.uint32

  regWrite(RiuMux, savedRiuMux)
  regWrite(RfDumpCfg, savedDumpCfg)
  regWrite(RfAdcCfg, savedAdc)
  regWrite(RfRxCfg, savedRx)
  regWrite(RfPuCtrl, savedPu)
  if (savedForce and 8'u32) != 0'u32:
    rfc_rf_fsm_force(savedForce and 7'u32)
  else:
    rfc_rf_fsm_force(15'u32)
    regModify(RfForce, 7'u32, savedForce and 7'u32)

  discard console.sendString("RF AUDIO TRACE CONFIG")
  emit("freq_mhz", CsiFrequencyMhz)
  emit("frames", TraceCount.uint32)
  emit("completed", completed)
  emit("interval_us", TraceIntervalUs)
  emit("words", CsiWords)
  emit("power_samples", PowerSamples.uint32)
  emit("probe_status", probe.status.uint32)
  emit("probe_stride", probe.strideWords)
  emit("failure", failure)
  emit("late_starts", lateStarts)
  emit("max_start_lag_us", maxStartLag)
  emit("engine_max_us", engineMaxUs)
  discard console.sendLine("")
  for index in 0'u32 ..< completed:
    discard console.sendString("RF AUDIO TRACE FRAME ")
    console.sendHex32(index)
    discard console.sendString(" ")
    console.sendHex32(powers[index])
    discard console.sendString(" ")
    console.sendHex32(rfGains[index].uint32)
    discard console.sendLine("")
  discard console.sendLine("RF AUDIO TRACE END")
  console.flushTx()
  while true:
    {.emit: "__asm__ volatile(\"wfi\");".}
