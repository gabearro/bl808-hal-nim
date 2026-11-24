## Time-stamped, packet-aligned RF SRAM LTF magnitudes. This diagnostic owns
## the receiver and runs only from the dedicated CSI RAM linker image.

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
  {.error: "Packet CSI trace requires -d:bl808CsiCapture".}

const
  ConsoleBaud {.intdefine.} = 230_400'u32
  ConsoleClkHz {.intdefine.} = 40_000_000'u32
  CsiFrequencyMhz {.intdefine.} = 2437'u32
  CsiDirectReadProbe {.intdefine.} = 0
  CsiModemClockProbe {.intdefine.} = 0
  CsiLtfGainTrace {.intdefine.} = 0
  TraceDurationUs {.intdefine.} = 1_000_000'u32
  CsiWords = 8000'u32
  MaxAttempts = 10_000
  # Leave room for the gain history in the reserved CSI RAM layout.
  MaxPackets = (if CsiLtfGainTrace == 1: 64 else: 512)
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
  RfAppliedGain = RfBase + 0x04C'u
  Rc2GainStatus = 0x24C0C908'u
  RiuDigitalGain = 0x24C0B210'u
  RawWordsPerUs = 40'u32
  RiuBank00And03 = 0x03010001'u32
  CsiPoison = 0xA5A0055A'u32
  DirectCsiCtl = 0x24C008F8'u
  DirectCsiStat = 0x24C00064'u
  DirectCsiWindow = 0x24C09000'u
  ModemClockForce = 0x24C00874'u
  # Every fourth sample of the IEEE 802.11 legacy LTF time template,
  # scaled by 4096. The full template is in tools/wifi_csi_estimate.py.
  LtfR: array[16, int32] = [
    640, 86, 400, 100, 256, 337, -144, -11,
    -640, -11, -144, 337, 256, 100, 400, 86]
  LtfI: array[16, int32] = [
    0, 114, -106, -240, -256, 378, -618, 220,
    0, -220, 618, -378, 256, 240, 106, -114]
  LtfEnergy = 3_015_068'i64
  Cos8: array[8, int32] = [4096, 2896, 0, -2896, -4096, -2896, 0, 2896]
  Sin8: array[8, int32] = [0, 2896, 4096, 2896, 0, -2896, -4096, -2896]

type
  GainSample = object
    startUs, endUs: uint32
    riu03, rf, rc2, digital: uint32
  LtfGainRecord = object
    ltfStartUs, ltfEndUs, samples, maxGapUs, unchangedMask: uint32
    first: GainSample
    lastUs: uint32
  PacketRecord = object
    timeUs, attempt, stfScore, ltfScore, ltfRepeat: uint32
    gainBefore, gainAfter: uint32
    magnitudes: array[4, uint32]

var console: Uart
var packets: array[MaxPackets, PacketRecord]

when CsiLtfGainTrace == 1:
  var captureGain: array[256, GainSample]
  var ltfGain: array[MaxPackets, LtfGainRecord]

  proc sampleGain(started: uint32): GainSample =
    result.startUs = regRead(0xE000BFF8'u) - started
    result.riu03 = regRead(RiuSecondDiag)
    result.rf = regRead(RfAppliedGain)
    result.rc2 = regRead(Rc2GainStatus)
    result.digital = regRead(RiuDigitalGain)
    result.endUs = regRead(0xE000BFF8'u) - started

  proc ltfGainRecord(ltfStart20: uint32; count: int): LtfGainRecord =
    # Round outward and allow two more ticks at either edge for trigger
    # and timestamp uncertainty. These are estimates from the dump start.
    let ltfStartUs = ltfStart20 * 2'u32 div RawWordsPerUs
    result.ltfStartUs = ltfStartUs
    result.ltfEndUs = ((ltfStart20 + 128'u32) * 2'u32 + RawWordsPerUs - 1'u32) div
      RawWordsPerUs
    let windowStart = (if ltfStartUs > 2'u32: ltfStartUs - 2'u32 else: 0'u32)
    let windowEnd = result.ltfEndUs + 2'u32
    var first = -1
    var last = -1
    for index in 0 ..< count:
      if captureGain[index].endUs <= windowStart:
        first = index
      if captureGain[index].startUs >= windowEnd:
        last = index
        break
    if first < 0 or last < 0:
      return
    result.first = captureGain[first]
    result.lastUs = captureGain[last].endUs
    result.samples = (last - first + 1).uint32
    result.unchangedMask = 0xF'u32
    for index in first + 1 .. last:
      let sample = captureGain[index]
      # Include the duration of adjacent reads in the uncertainty bound.
      result.maxGapUs = max(result.maxGapUs,
        sample.endUs - captureGain[index - 1].startUs)
      if ((sample.riu03 xor result.first.riu03) and 0xFF000000'u32) != 0:
        result.unchangedMask = result.unchangedMask and not 1'u32
      if ((sample.rf xor result.first.rf) and 0x7337'u32) != 0:
        result.unchangedMask = result.unchangedMask and not 2'u32
      if ((sample.rc2 xor result.first.rc2) and 0x0000FF00'u32) != 0:
        result.unchangedMask = result.unchangedMask and not 4'u32
      if ((sample.digital xor result.first.digital) and 0x7F'u32) != 0:
        result.unchangedMask = result.unchangedMask and not 8'u32

proc emit(label: string; value: uint32) =
  discard console.sendString(" ")
  discard console.sendString(label)
  discard console.sendString("=")
  console.sendHex32(value)

proc directWindowHash(): uint32 =
  result = 0x811C9DC5'u32
  for word in 0'u ..< 52'u:
    result = (result xor regRead(DirectCsiWindow + word * 4'u)) *
      0x01000193'u32

proc normSq(re, im, ea, eb: int32): uint32 {.inline.} =
  if ea <= 0 or eb <= 0:
    return 0'u32
  let numerator = re.float32 * re.float32 + im.float32 * im.float32
  let denominator = ea.float32 * eb.float32
  min((numerator * 1000.0'f32 / denominator).uint32, 1000'u32)

proc sample20(index: uint32): tuple[i, q: int32] {.inline.} =
  ## Tap 1 is provisionally 40 MS/s; pair averaging gives 20 MS/s.
  ## The low halfword is I and the high halfword Q in the packet examples.
  let a = csiSampleWord(index * 2'u32)
  let b = csiSampleWord(index * 2'u32 + 1'u32)
  result.i = ((cast[int16](a.uint16).int32 +
    cast[int16](b.uint16).int32) shr 1) + 5'i32
  result.q = ((cast[int16]((a shr 16).uint16).int32 +
    cast[int16]((b shr 16).uint16).int32) shr 1) - 55'i32

proc firstBurst(): uint32 =
  ## A packet-free 200-us frame should cost only sparse power checks.
  for raw in countup(0'u32, CsiWords - 1'u32, 32'u32):
    let word = csiSampleWord(raw)
    let i = cast[int16](word.uint16).int32 + 5'i32
    let q = cast[int16]((word shr 16).uint16).int32 - 55'i32
    if abs(i) <= 2048'i32 and abs(q) <= 2048'i32 and
        i * i + q * q >= 3_000'i32:
      return raw
  CsiWords

proc findStf(burstOffset: uint32): tuple[score, offset: uint32] =
  ## 32 raw samples = one 16-sample legacy short-training period.
  let low = (if burstOffset > 128'u32: burstOffset - 128'u32 else: 0'u32)
  let high = min(burstOffset + 512'u32, CsiWords - 96'u32)
  for start in countup(low, high, 32'u32):
    var re, im, ea, eb = 0'i32
    for n in 0'u32 ..< 64'u32:
      let a = csiSampleWord(start + n)
      let b = csiSampleWord(start + n + 32'u32)
      let ai = cast[int16](a.uint16).int32 + 5'i32
      let aq = cast[int16]((a shr 16).uint16).int32 - 55'i32
      let bi = cast[int16](b.uint16).int32 + 5'i32
      let bq = cast[int16]((b shr 16).uint16).int32 - 55'i32
      if max(max(abs(ai), abs(aq)), max(abs(bi), abs(bq))) > 2048'i32:
        return
      re += ai * bi + aq * bq
      im += ai * bq - aq * bi
      ea += ai * ai + aq * aq
      eb += bi * bi + bq * bq
    if min(ea, eb) < 64'i32 * 5_000'i32:
      continue
    let score = normSq(re, im, ea, eb)
    if score > result.score:
      result = (score, start)

proc findLtf(burstOffset: uint32): tuple[score, repeat, start: uint32] =
  ## In two offline-verified packets the LTF starts 362 and 368 raw words
  ## after the first threshold crossing. Scan a wider 300..440-word band.
  let low = burstOffset div 2'u32 + 150'u32
  let high = min(burstOffset div 2'u32 + 220'u32,
    CsiWords div 2'u32 - 128'u32)
  if low > high:
    return
  var bestQuality = 0'u32
  for start in low .. high:
    var ar, ai, br, bi, rr, ri = 0'i32
    var ea, eb = 0'i32
    for j in 0'u32 ..< 16'u32:
      let a = sample20(start + 4'u32 * j)
      let b = sample20(start + 64'u32 + 4'u32 * j)
      let tr = LtfR[j]
      let ti = LtfI[j]
      ar += tr * a.i + ti * a.q
      ai += tr * a.q - ti * a.i
      br += tr * b.i + ti * b.q
      bi += tr * b.q - ti * b.i
      rr += a.i * b.i + a.q * b.q
      ri += a.i * b.q - a.q * b.i
      ea += a.i * a.i + a.q * a.q
      eb += b.i * b.i + b.q * b.q
    if min(ea, eb) < 16'i32 * 5_000'i32:
      continue
    let sa = normSq(ar, ai, LtfEnergy.int32, ea)
    let sb = normSq(br, bi, LtfEnergy.int32, eb)
    let repeat = normSq(rr, ri, ea, eb)
    if min(sa, sb) < 350'u32 or repeat < 550'u32:
      continue
    let quality = min(sa, sb) * repeat div 1000'u32
    if quality > bestQuality:
      bestQuality = quality
      result = (min(sa, sb), repeat, start)

proc binMagnitude(start: uint32; bin: int32): uint32 =
  ## Two 64-sample LTF DFTs; the known transmitted tone has unit magnitude.
  var total = 0'i64
  for symbol in 0'u32 ..< 2'u32:
    var re, im = 0'i64
    for n in 0'u32 ..< 64'u32:
      let value = sample20(start + symbol * 64'u32 + n)
      let phase = (n * (abs(bin).uint32 div 8'u32)) mod 8'u32
      let c = Cos8[phase].int64
      let s = Sin8[phase].int64 * (if bin < 0'i32: -1'i64 else: 1'i64)
      re += value.i.int64 * c + value.q.int64 * s
      im += value.q.int64 * c - value.i.int64 * s
    total += re * re + im * im
  (total div (2'i64 * 4096'i64 * 4096'i64 * 64'i64 * 64'i64)).uint32

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
  discard console.sendLine("RF PACKET TRACE START")
  console.flushTx()

  if CsiFrequencyMhz < 2412'u32 or CsiFrequencyMhz > 2484'u32 or
      TraceDurationUs < 100_000'u32 or TraceDurationUs > 5_000_000'u32 or
      CsiDirectReadProbe notin [0, 1] or CsiModemClockProbe notin [0, 1] or
      CsiLtfGainTrace notin [0, 1] or
      (CsiModemClockProbe != 0 and CsiDirectReadProbe == 0):
    discard console.sendLine("RF PACKET TRACE INVALID")
    return

  rfc_init(40_000_000'u32)
  phySetChannel(1'u8, 0'u8, CsiFrequencyMhz.uint16,
                CsiFrequencyMhz.uint16, 0'u16, 0'u8)
  var modemClockBefore, modemClockForced = 0'u32
  if CsiModemClockProbe != 0:
    # BL808/M1s phy_init toggles bit 29 here around AGC memory copy.
    # This is a known modem clock-force field, not Beken's PHY AHB bit.
    modemClockBefore = regRead(ModemClockForce)
    regWrite(ModemClockForce, modemClockBefore or (1'u32 shl 29))
    modemClockForced = regRead(ModemClockForce)
  var directCtlBeforeForce, directEnableReadback, directRequestReadback = 0'u32
  if CsiDirectReadProbe != 0:
    directCtlBeforeForce = regRead(DirectCsiCtl)
    regWrite(DirectCsiCtl, directCtlBeforeForce or 2'u32)
    directEnableReadback = regRead(DirectCsiCtl)
    regWrite(DirectCsiCtl, directCtlBeforeForce or 3'u32)
    directRequestReadback = regRead(DirectCsiCtl)
    regWrite(DirectCsiCtl, directCtlBeforeForce)
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
  var directSavedCtl, directArmedCtl, directBeforeStat = 0'u32
  var directBeforeHash, directAfterHash, directStatusOr = 0'u32
  var directReadyCount, directErrorCount, directHashChanges = 0'u32
  if CsiDirectReadProbe != 0:
    directSavedCtl = regRead(DirectCsiCtl)
    directBeforeStat = regRead(DirectCsiStat)
    directBeforeHash = directWindowHash()
    regWrite(DirectCsiCtl, directSavedCtl or 3'u32)
    directArmedCtl = regRead(DirectCsiCtl)
  let probe = csiProbeSnapshot(1'u32, CsiPollLimit)

  var attempts, packetCount, burstCandidates, stfCandidates, failure = 0'u32
  var captureMaxUs, processingMaxUs, elapsedUs = 0'u32
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
    let traceStart = regRead(0xE000BFF8'u)
    while attempts < MaxAttempts.uint32 and packetCount < MaxPackets.uint32 and
        regRead(0xE000BFF8'u) - traceStart < TraceDurationUs:
      for position in 0 ..< 4:
        let wordIndex = (CsiWords - 1'u32) * position.uint32 div 3'u32
        volatileStore(cast[ptr uint32](CsiSampleBase + wordIndex.uint * 4'u),
          CsiPoison)
      regWrite(DumpCtrl, idleCtrl or DumpClear)
      regWrite(DumpCtrl, idleCtrl)
      let gainBefore = (regRead(RiuSecondDiag) shr 24) and 0xFF'u32
      if (regRead(DumpCtrl) and DumpDone) != 0'u32:
        failure = csiStaleDone.uint32
        break
      let started = regRead(0xE000BFF8'u)
      regWrite(DumpCtrl, idleCtrl or DumpEnable)
      var done = false
      when CsiLtfGainTrace == 1:
        var gainSamples = 0
      for poll in 0'u32 ..< CsiPollLimit:
        if (regRead(DumpCtrl) and DumpDone) != 0'u32:
          done = true
          break
        when CsiLtfGainTrace == 1:
          if gainSamples < captureGain.len:
            let sample = sampleGain(started)
            if gainSamples == 0 or sample.startUs > captureGain[gainSamples - 1].startUs:
              captureGain[gainSamples] = sample
              inc gainSamples
      let captureUs = regRead(0xE000BFF8'u) - started
      captureMaxUs = max(captureMaxUs, captureUs)
      regWrite(DumpCtrl, idleCtrl)
      if not done:
        failure = csiTimedOut.uint32
        break
      for position in 0 ..< 4:
        let wordIndex = (CsiWords - 1'u32) * position.uint32 div 3'u32
        if csiSampleWord(wordIndex) == CsiPoison:
          failure = csiNoBufferChange.uint32
      if failure != 0'u32:
        break
      if CsiDirectReadProbe != 0:
        let status = regRead(DirectCsiStat)
        directStatusOr = directStatusOr or status
        if (status and 1'u32) != 0'u32:
          inc directReadyCount
          if directWindowHash() != directBeforeHash:
            inc directHashChanges
        if (status and 2'u32) != 0'u32:
          inc directErrorCount
      let gainAfter = (regRead(RiuSecondDiag) shr 24) and 0xFF'u32
      inc attempts
      let processingStart = regRead(0xE000BFF8'u)
      let burst = firstBurst()
      if burst == CsiWords:
        processingMaxUs = max(processingMaxUs,
          regRead(0xE000BFF8'u) - processingStart)
        continue
      inc burstCandidates
      let stf = findStf(burst)
      if stf.score < 360'u32:
        processingMaxUs = max(processingMaxUs,
          regRead(0xE000BFF8'u) - processingStart)
        continue
      inc stfCandidates
      let ltf = findLtf(burst)
      if ltf.score == 0'u32:
        processingMaxUs = max(processingMaxUs,
          regRead(0xE000BFF8'u) - processingStart)
        continue
      packets[packetCount].timeUs = started - traceStart + stf.offset div RawWordsPerUs
      packets[packetCount].attempt = attempts
      packets[packetCount].stfScore = stf.score
      packets[packetCount].ltfScore = ltf.score
      packets[packetCount].ltfRepeat = ltf.repeat
      packets[packetCount].gainBefore = gainBefore
      packets[packetCount].gainAfter = gainAfter
      for binIndex, bin in [-16'i32, -8'i32, 8'i32, 16'i32]:
        packets[packetCount].magnitudes[binIndex] = binMagnitude(ltf.start, bin)
      when CsiLtfGainTrace == 1:
        ltfGain[packetCount] = ltfGainRecord(ltf.start, gainSamples)
      inc packetCount
      processingMaxUs = max(processingMaxUs,
        regRead(0xE000BFF8'u) - processingStart)
    elapsedUs = regRead(0xE000BFF8'u) - traceStart
    regWrite(DumpCtrl, idleCtrl or DumpClear)
    regWrite(DumpCtrl, idleCtrl)
    regWrite(DumpAddr, savedDumpAddr)
    regWrite(DumpSram, savedDumpSram)
  else:
    failure = csiInvalidRequest.uint32

  if CsiDirectReadProbe != 0:
    directAfterHash = directWindowHash()
    regWrite(DirectCsiCtl, directSavedCtl)
  if CsiModemClockProbe != 0:
    regWrite(ModemClockForce,
      (regRead(ModemClockForce) and not (1'u32 shl 29)) or
      (modemClockBefore and (1'u32 shl 29)))

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

  discard console.sendString("RF PACKET TRACE CONFIG")
  emit("freq_mhz", CsiFrequencyMhz)
  emit("duration_us", TraceDurationUs)
  emit("elapsed_us", elapsedUs)
  emit("attempts", attempts)
  emit("burst_candidates", burstCandidates)
  emit("stf_candidates", stfCandidates)
  emit("packets", packetCount)
  emit("capture_max_us", captureMaxUs)
  emit("processing_max_us", processingMaxUs)
  emit("probe_status", probe.status.uint32)
  emit("probe_stride", probe.strideWords)
  emit("failure", failure)
  when CsiLtfGainTrace == 1:
    emit("ltf_gain_trace", 1'u32)
  if CsiDirectReadProbe != 0:
    if CsiModemClockProbe != 0:
      emit("modem_clk_before", modemClockBefore)
      emit("modem_clk_forced", modemClockForced)
      emit("modem_clk_restored", regRead(ModemClockForce))
    emit("direct_modem_cfg", regRead(0x24C00000'u))
    emit("direct_modem_version", regRead(0x24C0003C'u))
    emit("direct_modem_clk", regRead(0x24C00874'u))
    emit("direct_ctl_before_force", directCtlBeforeForce)
    emit("direct_enable_readback", directEnableReadback)
    emit("direct_request_readback", directRequestReadback)
    emit("direct_ctl_before", directSavedCtl)
    emit("direct_ctl_armed", directArmedCtl)
    emit("direct_ctl_restored", regRead(DirectCsiCtl))
    emit("direct_stat_before", directBeforeStat)
    emit("direct_stat_after", regRead(DirectCsiStat))
    emit("direct_status_or", directStatusOr)
    emit("direct_ready_count", directReadyCount)
    emit("direct_error_count", directErrorCount)
    emit("direct_hash_before", directBeforeHash)
    emit("direct_hash_after", directAfterHash)
    emit("direct_hash_changes", directHashChanges)
  discard console.sendLine("")
  for index in 0'u32 ..< packetCount:
    let packet = packets[index]
    discard console.sendString("RF PACKET TRACE PACKET ")
    console.sendHex32(index)
    for value in [packet.timeUs, packet.attempt, packet.stfScore,
        packet.ltfScore, packet.ltfRepeat, packet.gainBefore,
        packet.gainAfter, packet.magnitudes[0], packet.magnitudes[1],
        packet.magnitudes[2], packet.magnitudes[3]]:
      discard console.sendString(" ")
      console.sendHex32(value)
    discard console.sendLine("")
    when CsiLtfGainTrace == 1:
      let gain = ltfGain[index]
      discard console.sendString("RF PACKET TRACE LTF GAIN ")
      console.sendHex32(index)
      for value in [gain.ltfStartUs, gain.ltfEndUs, gain.samples,
          gain.first.startUs, gain.lastUs, gain.maxGapUs, gain.unchangedMask,
          gain.first.riu03, gain.first.rf, gain.first.rc2, gain.first.digital]:
        discard console.sendString(" ")
        console.sendHex32(value)
      discard console.sendLine("")
  discard console.sendLine("RF PACKET TRACE END")
  console.flushTx()
  while true:
    {.emit: "__asm__ volatile(\"wfi\");".}
