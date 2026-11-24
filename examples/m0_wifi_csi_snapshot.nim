## One finite, opt-in RF SRAM RX capture. Build only with -d:bl808CsiCapture;
## this image uses a linker map that keeps all firmware state out of OCRAM.

import bl808/startup, bl808/core
import bl808/glb, bl808/gpio, bl808/uart
import bl808/mmio
import bl808/panicoverride
import bl808/kernel/alloc
import bl808/wifi
import bl808/wifi_fw
import bl808/wifi/csi_capture

when not defined(bl808CsiCapture):
  {.error: "CSI capture requires -d:bl808CsiCapture".}

const
  ConsoleBaud {.intdefine.} = 230_400'u32
  ConsoleClkHz {.intdefine.} = 40_000_000'u32
  CsiFrequencyMhz {.intdefine.} = 2412'u32
  CsiWords {.intdefine.} = 4000'u32
  CsiTap {.intdefine.} = 1'u32
  CsiPollLimit {.intdefine.} = 2_000_000'u32
  CsiSearchAttempts {.intdefine.} = 1
  CsiSearchThreshold {.intdefine.} = 50_000'u32
  CsiSearchPreamble {.intdefine.} = 0
  CsiSearchCorrSquared {.intdefine.} = 360_000'u32
  RfBase = CsiRfBase
  RfPuCtrl = RfBase + 0x02C'u
  RfRxCfg = RfBase + 0x048'u
  RfAdcCfg = RfBase + 0x088'u
  RfDumpCfg = RfBase + 0x220'u
  RfForce = RfBase + 0x26C'u

var console: Uart

proc emitField(label: string; value: uint32) =
  discard console.sendString(" ")
  discard console.sendString(label)
  discard console.sendString("=")
  console.sendHex32(value)

proc findRepeated32(words: uint32): tuple[score, offset: uint32] =
  ## Compare 64 raw words with the following 64 shifted by 32 words.
  ## A high normalized complex correlation is a candidate 40-MS/s STF,
  ## still requiring the offline LTF template check.
  for start in countup(0'u32, words - 96'u32, 32'u32):
    var re, im, ea, eb = 0'i64
    for offset in 0'u32 ..< 64'u32:
      let a = csiSampleWord(start + offset)
      let b = csiSampleWord(start + offset + 32'u32)
      let ai = cast[int16]((a shr 16).uint16).int64 - 55'i64
      let aq = cast[int16](a.uint16).int64 + 5'i64
      let bi = cast[int16]((b shr 16).uint16).int64 - 55'i64
      let bq = cast[int16](b.uint16).int64 + 5'i64
      re += ai * bi + aq * bq
      im += ai * bq - aq * bi
      ea += ai * ai + aq * aq
      eb += bi * bi + bq * bq
    if min(ea, eb) < 64'i64 * 5_000'i64:
      continue
    let scaled = ((re.float64 * re.float64 + im.float64 * im.float64) *
      1_000_000.0 / (ea.float64 * eb.float64)).uint32
    if scaled > result.score:
      result = (scaled, start)

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

  if CsiFrequencyMhz < 2412'u32 or CsiFrequencyMhz > 2484'u32 or
      CsiWords < CsiProbeWords or CsiWords > CsiWindowWords - 64'u32 or
      CsiTap > 1'u32 or CsiSearchAttempts < 1 or CsiSearchAttempts > 128 or
      CsiSearchPreamble notin [0, 1] or
      CsiSearchCorrSquared > 1_000_000'u32:
    discard console.sendLine("CSI1 ERROR invalid build parameters")
    return

  # This diagnostic owns the radio. It does not start the MAC or alter the
  # ordinary WiFi initialization path used by other images.
  rfc_init(40_000_000'u32)
  phySetChannel(1'u8, 0'u8, CsiFrequencyMhz.uint16,
                CsiFrequencyMhz.uint16, 0'u16, 0'u8)

  let savedForce = regRead(RfForce)
  let savedPu = regRead(RfPuCtrl)
  let savedRx = regRead(RfRxCfg)
  let savedAdc = regRead(RfAdcCfg)
  let savedDumpCfg = regRead(RfDumpCfg)

  rfc_rf_fsm_force(3'u32)
  # BL618's working sram_rx setup is a starting point. The BL808 M1s
  # diagnostic confirms the dump controls, not these RX gain/clock values.
  regWrite(RfPuCtrl, savedPu and not 2'u32)
  regWrite(RfRxCfg, (savedRx and not 0x731F'u32) or 0x311F'u32)
  regWrite(RfAdcCfg, (savedAdc and not 0x03000000'u32) or 0x03000000'u32)
  regWrite(RfDumpCfg, savedDumpCfg or 0x1E3'u32)

  let probe = csiProbeSnapshot(CsiTap, CsiPollLimit)
  var capture = probe
  var attemptsUsed = 0'u32
  var searchPower = 0'u32
  var triggerHit = 0'u32
  var searchCorr = 0'u32
  var searchCorrOffset = 0'u32
  if probe.status == csiCaptured:
    for attempt in 1 .. CsiSearchAttempts:
      capture = csiCaptureSnapshot(probe, CsiWords, CsiPollLimit)
      attemptsUsed = attempt.uint32
      if capture.status != csiCaptured:
        break
      # A sparse activity check picks a raw frame to preserve. It is not
      # packet detection, RSSI, or a channel estimate.
      var power = 0'u32
      for sample in 0 ..< 16:
        let wordIndex = sample.uint32 * CsiWords div 16'u32
        let word = csiSampleWord(wordIndex)
        let i = cast[int16]((word shr 16).uint16).int32 - 55'i32
        let q = cast[int16](word.uint16).int32 + 5'i32
        power += (i * i + q * q).uint32
      searchPower = power
      if CsiSearchPreamble != 0 and power >= CsiSearchThreshold:
        let repeated = findRepeated32(CsiWords)
        searchCorr = repeated.score
        searchCorrOffset = repeated.offset
      if power >= CsiSearchThreshold and
          (CsiSearchPreamble == 0 or searchCorr >= CsiSearchCorrSquared):
        triggerHit = 1'u32
        break

  var rawHash = 0x811C9DC5'u32
  if capture.status == csiCaptured:
    for i in 0'u32 ..< capture.memoryWords:
      rawHash = (rawHash xor csiSampleWord(i)) * 0x01000193'u32

  regWrite(RfDumpCfg, savedDumpCfg)
  regWrite(RfAdcCfg, savedAdc)
  regWrite(RfRxCfg, savedRx)
  regWrite(RfPuCtrl, savedPu)
  if (savedForce and 8'u32) != 0'u32:
    rfc_rf_fsm_force(savedForce and 7'u32)
  else:
    rfc_rf_fsm_force(15'u32)
    regModify(RfForce, 7'u32, savedForce and 7'u32)

  discard console.sendString("CSI1 BEGIN")
  emitField("version", 1'u32)
  emitField("status", capture.status.uint32)
  emitField("search_attempts", attemptsUsed)
  emitField("search_power", searchPower)
  emitField("trigger_hit", triggerHit)
  emitField("search_corr_squared_million", searchCorr)
  emitField("search_corr_offset", searchCorrOffset)
  emitField("freq_mhz", CsiFrequencyMhz)
  emitField("tap", CsiTap)
  emitField("rate_hz_nominal", if CsiTap == 1'u32: 40_000_000'u32 else: 80_000_000'u32)
  emitField("start_index", CsiStartIndex)
  emitField("base", CsiSampleBase.uint32)
  emitField("words", capture.words)
  emitField("memory_words", capture.memoryWords)
  emitField("stride_words", capture.strideWords)
  emitField("probe_status", probe.status.uint32)
  emitField("probe_stride", probe.strideWords)
  emitField("probe_end_extra", probe.endExtraChanged)
  emitField("changed", capture.changedWords)
  emitField("stray", capture.strayWords)
  emitField("end_extra", capture.endExtraChanged)
  emitField("raw_fnv32", rawHash)
  emitField("ctrl_before", capture.ctrlBefore)
  emitField("ctrl_done", capture.ctrlDone)
  emitField("status_done", capture.statusDone)
  discard console.sendLine("")

  if capture.status == csiCaptured:
    for i in 0'u32 ..< capture.memoryWords:
      discard console.sendString("CSI1 WORD ")
      console.sendHex32(i)
      discard console.sendString(" ")
      console.sendHex32(csiSampleWord(i))
      discard console.sendLine("")
  discard console.sendLine("CSI1 END")
  console.flushTx()
  while true:
    {.emit: "__asm__ volatile(\"wfi\");".}
