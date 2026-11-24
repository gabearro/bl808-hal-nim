## RAM-loaded RF SRAM repeated-capture timing, without dumping samples.

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
  {.error: "RF cadence probe requires -d:bl808CsiCapture".}

const
  ConsoleBaud {.intdefine.} = 230_400'u32
  ConsoleClkHz {.intdefine.} = 40_000_000'u32
  CsiFrequencyMhz {.intdefine.} = 2412'u32
  CsiWords {.intdefine.} = 4000'u32
  CsiTap {.intdefine.} = 1'u32
  CaptureCount {.intdefine.} = 16
  CsiFastMode {.intdefine.} = 0
  CsiTimedMode {.intdefine.} = 0
  CsiPowerMode {.intdefine.} = 0
  CsiPowerSamples {.intdefine.} = 16
  CsiPollLimit {.intdefine.} = 2_000_000'u32
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
  CsiPoison = 0xA5A0055A'u32

var console: Uart
var durations: array[CaptureCount, uint32]
var engineDurations: array[CaptureCount, uint32]
var statuses: array[CaptureCount, uint32]
var changed: array[CaptureCount, uint32]
var stray: array[CaptureCount, uint32]
var hashes: array[CaptureCount, uint32]
var startOffsets: array[CaptureCount, uint32]
var powers: array[CaptureCount, uint32]

proc printHex(value: uint32) =
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
  discard console.sendLine("CSI CADENCE START")
  console.flushTx()

  if CsiWords < CsiProbeWords or CsiWords > CsiWindowWords - 64'u32 or
      CsiTap > 1'u32 or CaptureCount < 1 or
      CsiFrequencyMhz < 2412'u32 or CsiFrequencyMhz > 2484'u32 or
      CsiPowerSamples < 1 or CsiPowerSamples > CsiWords.int:
    discard console.sendLine("CSI CADENCE INVALID")
    return

  rfc_init(40_000_000'u32)
  phySetChannel(1'u8, 0'u8, CsiFrequencyMhz.uint16,
                CsiFrequencyMhz.uint16, 0'u16, 0'u8)
  let savedForce = regRead(RfForce)
  let savedPu = regRead(RfPuCtrl)
  let savedRx = regRead(RfRxCfg)
  let savedAdc = regRead(RfAdcCfg)
  let savedDumpCfg = regRead(RfDumpCfg)
  rfc_rf_fsm_force(3'u32)
  regWrite(RfPuCtrl, savedPu and not 2'u32)
  regWrite(RfRxCfg, (savedRx and not 0x731F'u32) or 0x311F'u32)
  regWrite(RfAdcCfg, (savedAdc and not 0x03000000'u32) or 0x03000000'u32)
  regWrite(RfDumpCfg, savedDumpCfg or 0x1E3'u32)

  let probe = csiProbeSnapshot(CsiTap, CsiPollLimit)
  when CsiTimedMode != 0:
    if probe.status == csiCaptured and probe.strideWords == 1'u32:
      let savedDumpSram = regRead(DumpSram)
      let savedDumpAddr = regRead(DumpAddr)
      let savedDumpCtrl = regRead(DumpCtrl)
      let idleCtrl = savedDumpCtrl and 0x0000FFF0'u32
      regWrite(RfDumpCfg, (regRead(RfDumpCfg) and not (3'u32 shl 9)) or
        ((CsiTap and 3'u32) shl 9))
      regWrite(DumpSram, savedDumpSram and not (7'u32 shl 16))
      regWrite(DumpAddr, (CsiStartIndex shl 16) or (CsiStartIndex + CsiWords))
      let baseTick = regRead(0xE000BFF8'u) + 250'u32
      for index in 0 ..< CaptureCount:
        let prepStart = regRead(0xE000BFF8'u)
        for position in 0 ..< 4:
          let wordIndex = (CsiWords - 1'u32) * position.uint32 div 3'u32
          volatileStore(cast[ptr uint32](CsiSampleBase + wordIndex.uint * 4'u),
            CsiPoison)
        regWrite(DumpCtrl, idleCtrl or DumpClear)
        regWrite(DumpCtrl, idleCtrl)
        let targetTick = baseTick + index.uint32 * 125'u32
        while regRead(0xE000BFF8'u) < targetTick:
          discard
        let engineStart = regRead(0xE000BFF8'u)
        startOffsets[index] = engineStart - baseTick
        if (regRead(DumpCtrl) and DumpDone) != 0'u32:
          statuses[index] = csiStaleDone.uint32
        else:
          regWrite(DumpCtrl, idleCtrl or DumpEnable)
          var done = false
          for poll in 0'u32 ..< CsiPollLimit:
            if (regRead(DumpCtrl) and DumpDone) != 0'u32:
              done = true
              break
          engineDurations[index] = regRead(0xE000BFF8'u) - engineStart
          statuses[index] = (if done: csiCaptured else: csiTimedOut).uint32
        regWrite(DumpCtrl, idleCtrl)
        var rawHash = 0x811C9DC5'u32
        for position in 0 ..< 4:
          let wordIndex = (CsiWords - 1'u32) * position.uint32 div 3'u32
          let word = csiSampleWord(wordIndex)
          if word != CsiPoison:
            inc changed[index]
          rawHash = (rawHash xor word) * 0x01000193'u32
        hashes[index] = rawHash
        when CsiPowerMode != 0:
          # Relative RF activity only: fixed tap-1 DC center from the idle
          # captures, with sparse samples spread over the 256-word window.
          # This is neither calibrated RSSI nor packet-aligned CSI.
          var total = 0'u32
          for sample in 0 ..< CsiPowerSamples:
            let wordIndex = sample.uint32 * CsiWords div CsiPowerSamples.uint32
            let word = csiSampleWord(wordIndex)
            let i = cast[int16]((word shr 16).uint16).int32 - 55'i32
            let q = cast[int16](word.uint16).int32 + 5'i32
            total += (i * i + q * q).uint32
          powers[index] = total
        stray[index] = 0xFFFF_FFFF'u32 # Not scanned in timed mode.
        if statuses[index] == csiCaptured.uint32 and changed[index] != 4'u32:
          statuses[index] = csiNoBufferChange.uint32
        durations[index] = regRead(0xE000BFF8'u) - prepStart
      regWrite(DumpCtrl, idleCtrl or DumpClear)
      regWrite(DumpCtrl, idleCtrl)
      regWrite(DumpAddr, savedDumpAddr)
      regWrite(DumpSram, savedDumpSram)
    else:
      for index in 0 ..< CaptureCount:
        statuses[index] = csiInvalidRequest.uint32
  elif CsiFastMode != 0:
    if probe.status == csiCaptured and probe.strideWords == 1'u32:
      let savedDumpSram = regRead(DumpSram)
      let savedDumpAddr = regRead(DumpAddr)
      let savedDumpCtrl = regRead(DumpCtrl)
      let idleCtrl = savedDumpCtrl and 0x0000FFF0'u32
      regWrite(RfDumpCfg, (regRead(RfDumpCfg) and not (3'u32 shl 9)) or
        ((CsiTap and 3'u32) shl 9))
      regWrite(DumpSram, savedDumpSram and not (7'u32 shl 16))
      regWrite(DumpAddr, (CsiStartIndex shl 16) or (CsiStartIndex + CsiWords))
      for index in 0 ..< CaptureCount:
        let callStart = regRead(0xE000BFF8'u)
        for wordIndex in 0'u32 ..< CsiWords:
          volatileStore(cast[ptr uint32](CsiSampleBase + wordIndex.uint * 4'u),
            CsiPoison)
        regWrite(DumpCtrl, idleCtrl or DumpClear)
        regWrite(DumpCtrl, idleCtrl)
        if (regRead(DumpCtrl) and DumpDone) != 0'u32:
          statuses[index] = csiStaleDone.uint32
        else:
          let engineStart = regRead(0xE000BFF8'u)
          regWrite(DumpCtrl, idleCtrl or DumpEnable)
          var done = false
          for poll in 0'u32 ..< CsiPollLimit:
            if (regRead(DumpCtrl) and DumpDone) != 0'u32:
              done = true
              break
          let engineEnd = regRead(0xE000BFF8'u)
          engineDurations[index] = engineEnd - engineStart
          statuses[index] = (if done: csiCaptured else: csiTimedOut).uint32
        regWrite(DumpCtrl, idleCtrl)
        var rawHash = 0x811C9DC5'u32
        for wordIndex in 0'u32 ..< CsiWords:
          let word = csiSampleWord(wordIndex)
          if word != CsiPoison:
            inc changed[index]
          rawHash = (rawHash xor word) * 0x01000193'u32
        hashes[index] = rawHash
        stray[index] = 0xFFFF_FFFF'u32 # Not scanned in fast timing mode.
        if statuses[index] == csiCaptured.uint32 and
            changed[index] < (CsiWords * 3'u32) div 4'u32:
          statuses[index] = csiNoBufferChange.uint32
        durations[index] = regRead(0xE000BFF8'u) - callStart
      regWrite(DumpCtrl, idleCtrl or DumpClear)
      regWrite(DumpCtrl, idleCtrl)
      regWrite(DumpAddr, savedDumpAddr)
      regWrite(DumpSram, savedDumpSram)
    else:
      for index in 0 ..< CaptureCount:
        statuses[index] = csiInvalidRequest.uint32
  else:
    for index in 0 ..< CaptureCount:
      let startTick = regRead(0xE000BFF8'u)
      let capture = csiCaptureSnapshot(probe, CsiWords, CsiPollLimit)
      let endTick = regRead(0xE000BFF8'u)
      durations[index] = endTick - startTick
      statuses[index] = capture.status.uint32
      changed[index] = capture.changedWords
      stray[index] = capture.strayWords

  regWrite(RfDumpCfg, savedDumpCfg)
  regWrite(RfAdcCfg, savedAdc)
  regWrite(RfRxCfg, savedRx)
  regWrite(RfPuCtrl, savedPu)
  if (savedForce and 8'u32) != 0'u32:
    rfc_rf_fsm_force(savedForce and 7'u32)
  else:
    rfc_rf_fsm_force(15'u32)
    regModify(RfForce, 7'u32, savedForce and 7'u32)

  discard console.sendString("CSI CADENCE CONFIG ")
  printHex(CsiWords)
  discard console.sendString(" ")
  printHex(CsiTap)
  discard console.sendString(" ")
  printHex(CaptureCount.uint32)
  discard console.sendString(" ")
  printHex(probe.status.uint32)
  discard console.sendString(" ")
  printHex(probe.strideWords)
  discard console.sendString(" ")
  printHex(CsiFastMode.uint32)
  discard console.sendString(" ")
  printHex(CsiTimedMode.uint32)
  discard console.sendString(" ")
  printHex(CsiFrequencyMhz)
  discard console.sendString(" ")
  printHex(CsiPowerMode.uint32)
  discard console.sendString(" ")
  printHex(CsiPowerSamples.uint32)
  discard console.sendLine("")
  for index in 0 ..< CaptureCount:
    discard console.sendString("CSI CADENCE CASE ")
    printHex(index.uint32)
    discard console.sendString(" ")
    printHex(durations[index])
    discard console.sendString(" ")
    printHex(statuses[index])
    discard console.sendString(" ")
    printHex(changed[index])
    discard console.sendString(" ")
    printHex(stray[index])
    discard console.sendString(" ")
    printHex(engineDurations[index])
    discard console.sendString(" ")
    printHex(hashes[index])
    discard console.sendString(" ")
    printHex(startOffsets[index])
    discard console.sendString(" ")
    printHex(powers[index])
    discard console.sendLine("")
  discard console.sendLine("CSI CADENCE END")
  console.flushTx()
  while true:
    {.emit: "__asm__ volatile(\"wfi\");".}
