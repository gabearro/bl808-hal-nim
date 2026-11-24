# ###########################################################################
#                   RC: Rate Control
# ###########################################################################

include rate_duration_tables

when defined(bl808m0):
  proc rcInvalidateRateSamples(stats: pointer) =
    let offset = cast[uint](stats) - cast[uint](addr rcStaStatsPool[0])
    if offset < rcRateSampleEpoch.len.uint * RC_STATS_SIZE.uint and
        offset mod RC_STATS_SIZE.uint == 0:
      let staIdx = offset div RC_STATS_SIZE.uint
      rcRateSampleEpoch[staIdx] = rcRateSampleEpoch[staIdx] + 1'u16

  proc rcHasDuplicateSampleEncoding(stats: pointer; sampleCount: int): bool =
    for index in 1 ..< sampleCount:
      let encoding = rcRateConfig(stats, index) and 0x3FFF'u16
      for previous in 0 ..< index:
        if (rcRateConfig(stats, previous) and 0x3FFF'u16) == encoding:
          return true

proc rc_count_samples(stats: pointer): uint16 =
  if stats == nil:
    return 0
  let caps = rcRateCapabilities(stats)
  if caps.formatMod > 3 or caps.preambleType > 1 or caps.shortGi > 1:
    return 0
  var count = (caps.legacyRateMap and 1).int
  for cckRateBitIndex in 1 .. 3:
    if (caps.legacyRateMap and (1'u16 shl cckRateBitIndex)) != 0:
      count += 1 shl (1 - caps.preambleType.int)
  if caps.formatMod <= 1:
    for ofdmRateBitIndex in 4 .. 11:
      count += ((caps.legacyRateMap shr ofdmRateBitIndex) and 1).int
  else:
    for mcs in 0 .. 7:
      count += ((caps.mcsBitmaps[0] shr mcs) and 1).int shl caps.shortGi.int
  min(count, RC_MAX_RATE_ENTRIES).uint16

proc rc_seed_rate_table(stats: pointer): bool =
  ## Failure leaves samples unchanged; a smaller usable table is a success.
  if stats == nil:
    return false
  let caps = rcRateCapabilities(stats)
  let requested = caps.sampleCount.int
  if requested == 0 or requested > RC_MAX_RATE_ENTRIES:
    return false
  let lowest = rc_get_lowest_rate_config(stats)
  let initial = rc_get_initial_rate_config(stats)
  if lowest == 0xFFFF'u16 or initial == 0xFFFF'u16:
    return false
  when defined(bl808m0):
    rcInvalidateRateSamples(stats)
  for rateEntryIndex in 0 ..< requested:
    rcSetRateConfig(stats, rateEntryIndex, 0xFFFF'u16)
  rcSetRateConfig(stats, 0, lowest)
  # rc.o:rc_init reserves both endpoints even if they name the same rate.
  let fillEnd = requested - 1
  rcSetRateConfig(stats, fillEnd, initial)
  var sampleRateEntryIndex = 1
  while sampleRateEntryIndex < fillEnd:
    let randomRate = rc_pick_non_duplicate_rate(stats)
    if randomRate == 0xFFFF'u16:
      # Keep both endpoints when compacting an exhausted random fill.
      let retained = sampleRateEntryIndex + 1
      rcSetRateConfig(stats, sampleRateEntryIndex, initial)
      for unused in retained ..< requested:
        rcSetRateConfig(stats, unused, 0xFFFF'u16)
      caps.sampleCount = retained.uint16
      return true
    rcSetRateConfig(stats, sampleRateEntryIndex, randomRate)
    inc sampleRateEntryIndex
  true

proc rcKeepCckFallbackReachable(stats: pointer): bool =
  let caps = rcRateCapabilities(stats)
  # The BL808 default budget reaches two four-attempt rate slots. Change
  # the tracked index, not just the DMA rate word.
  const cck1Mbps = 0x0400'u16
  const usableProbability = 0x1999'u16
  const likelySuccess = 0x8000'u16
  if caps.fixedRate != 0xFFFF'u16 or caps.formatMod != RC_FORMATMOD_HT_MF or
      (caps.legacyRateMap and 1) == 0 or
      (rcU8(stats, RCS_ANOTHER_FLAG) and 3) != 0:
    return false
  let primary = rcRetryStep(stats, 0)
  let second = rcRetryStep(stats, 1)
  let lowest = rcRetryStep(stats, 3)
  let count = caps.sampleCount
  if count > RC_MAX_RATE_ENTRIES.uint16 or
      primary.rateIdx >= count or second.rateIdx >= count or lowest.rateIdx >= count:
    return false
  let bestSample = rcRateStats(stats, primary.rateIdx.int)
  let secondSample = rcRateStats(stats, second.rateIdx.int)
  let lowestSample = rcRateStats(stats, lowest.rateIdx.int)
  if lowestSample.rateConfig != cck1Mbps or bestSample.rateConfig == cck1Mbps or
      secondSample.rateConfig == cck1Mbps:
    return false
  let leadingProbability = max(bestSample.probability, secondSample.probability)
  let coldNonCck = leadingProbability < usableProbability and
    not is_cck_group(bestSample.rateConfig.uint32) and
    not is_cck_group(secondSample.rateConfig.uint32)
  var fallbackIdx = lowest.rateIdx
  var fallbackProbability = 0'u16
  if leadingProbability < likelySuccess:
    for index in 0 ..< count.int:
      let sample = rcRateStats(stats, index)
      if sample.oldProbAvailable != 0 and sample.probability >= likelySuccess and
          sample.probability > fallbackProbability and
          is_cck_group(sample.rateConfig.uint32) and
          rc_check_valid_rate(stats, sample.rateConfig) != 0:
        fallbackIdx = index.uint16
        fallbackProbability = sample.probability
  if not coldNonCck and fallbackProbability == 0:
    return false
  second.rateIdx = fallbackIdx
  second.throughput =
    if fallbackIdx == lowest.rateIdx: lowest.throughput
    else: rc_calc_tp(stats, fallbackIdx.uint8)
  true

when defined(bl808m0):
  proc rcInvalidateTrialTag(staIdx: uint8) {.inline.} =
    if staIdx < rcTrialSerial.len.uint8:
      # Preserve the serial so arming the next trial cannot reuse it.
      rcTrialSerial[staIdx] = rcTrialSerial[staIdx] or 0x8000_0000'u32

  proc rcArmedRateTrial(staIdx: uint8; stats: pointer; includeCompleted = false):
      tuple[tag: uint32, config: uint32, sampleIndex: uint16] =
    if staIdx >= rcTrialSerial.len.uint8 or stats == nil:
      return
    let serial = rcTrialSerial[staIdx]
    if serial == 0 or (serial and 0x8000_0000'u32) != 0:
      return
    let control = rcTrialControl(stats)
    let caps = rcRateCapabilities(stats)
    if (control.status != 2 and (not includeCompleted or control.status != 3)) or
        caps.fixedRate != 0xFFFF or
        caps.sampleCount > RC_MAX_RATE_ENTRIES.uint16:
      return
    let logicalSlot = ((control.info shr 1) and 1).int
    let index = rcRetryStep(stats, logicalSlot).rateIdx
    if index >= caps.sampleCount:
      return
    let physicalSlot = (logicalSlot + 4 - (rcU8(stats, RCS_ANOTHER_FLAG) and 3).int) and 3
    (serial shl 2 or physicalSlot.uint32,
     rcRateConfig(stats, index.int).uint32 and 0x3FFF, index)

  proc rcRejectUnprogrammedTrial(staIdx: uint8; stats: pointer;
                                rateWords: array[4, uint32]) =
    let trial = rcArmedRateTrial(staIdx, stats)
    if trial.tag == 0:
      return
    let programmed = rateWords[(trial.tag and 3).int] and 0x8000_3FFF'u32
    if programmed != (0x8000_0000'u32 or trial.config):
      # Request chain restoration without crediting a trial that cannot run.
      rcInvalidateTrialTag(staIdx)
      rcStatsCounters(stats).updateStage = 3

proc rcTryInitStation(staEntry: pointer): bool =
  ## Initialize capabilities, samples, and the station's hardware TX policy.
  if staEntry == nil:
    return false
  let sta = staInfoAt(staEntry)
  let infoIdx = sta.infoIdx
  if infoIdx > 4 or (infoIdx.int + 1) * RC_STATS_SIZE > rcStaStatsPool.len:
    assert_err("rc.c", "rc.c", 0x858.cint)
    return false
  let txPolicy = sta.txPolicy
  if txPolicy == nil:
    assert_err("rc.c", "rc.c", 0x858.cint)
    return false
  let stationEpoch = staDeleteEpoch(infoIdx)
  if not staDeleteIsCurrent(infoIdx, stationEpoch) or staInfoForIdx(infoIdx) != sta:
    return false
  let ownerVif = sta.vif
  let ownerVifIdx = sta.instNbr
  if ownerVifIdx >= MAX_VIFS.uint8:
    return false
  let ownerVifEpoch = rxVifEpochs[ownerVifIdx]

  let stats = cast[pointer](cast[uint](addr rcStaStatsPool[0]) +
    infoIdx.uint * RC_STATS_SIZE.uint)
  when defined(bl808m0):
    rcInvalidateTrialTag(infoIdx)
    rcInvalidateRateSamples(stats)
  sta.rcStats = stats
  let ntx = phy_get_ntx()
  var bufAddr = ntx.uint32 shl 14
  discard c_memset(stats, 0, RC_STATS_SIZE.csize_t)
  let caps = rcRateCapabilities(stats)
  let isHT = (sta.capabilityFlags and 2) != 0
  let legacyRateMap =
    me_legacy_rate_bitfield_build(cast[pointer](addr sta.supportedRates[0]), 0).uint16
  # Unsupported-rate warnings may retire or replace the station synchronously.
  if sta.infoIdx != infoIdx or not staDeleteIsCurrent(infoIdx, stationEpoch) or
      sta.txPolicy != txPolicy or sta.rcStats != stats or sta.vif != ownerVif or
      sta.instNbr != ownerVifIdx or rxVifEpochs[ownerVifIdx] != ownerVifEpoch:
    return false
  caps.legacyRateMap = legacyRateMap

  if isHT:
    caps.formatMod = RC_FORMATMOD_HT_MF
    let peerMcs = cast[pointer](cast[uint](addr sta.vhtCaps[0]) +
      (STA_HT_MCS_SET_OFF - STA_HT_CAP_INFO_OFF).uint)
    let peerNss = me_11n_nss_max(peerMcs)
    let localNss = me_11n_nss_max(addr meEnvView().htCaps[3])
    caps.maxNss = min(peerNss, localNss)
    if caps.maxNss >= caps.mcsBitmaps.len.uint8:
      assert_err("rc.c", "rc.c", 0x89F.cint)
      return false
    discard c_memcpy(addr caps.mcsBitmaps[0], peerMcs, 4.csize_t)
    let preserveStationRates = when defined(bl808WifiNativeWlanCalibration):
      caps.maxNss == 0 and vifChannelForIdx(ownerVifIdx).vifType == VIF_TYPE_STA
    else:
      false
    if preserveStationRates:
      caps.mcsBitmaps[0] = caps.mcsBitmaps[0] and meEnvView().htCaps[3]
      if caps.mcsBitmaps[0] == 0:
        return false
      caps.maxMcs = rcHighestBit(caps.mcsBitmaps[0])
    else:
      caps.mcsBitmaps[0] = 0xFF
      caps.maxMcs = 7

  caps.lowestLegacyRate = me_legacy_ridx_min(caps.legacyRateMap.uint32)
  caps.highestLegacyRate = me_legacy_ridx_max(caps.legacyRateMap.uint32)
  let maxLegacyIndex = if isHT: 12'u8 else: 11'u8
  if caps.lowestLegacyRate > maxLegacyIndex or caps.highestLegacyRate > maxLegacyIndex:
    assert_err("rc.c", "rc.c", 0x8ED.cint)
    return false
  caps.preambleType = ((sta.supportedRatesBitmap shr 10) and 1).uint8

  if isHT:
    let htCapInfo = cast[ptr uint16](addr sta.vhtCaps[0])[]
    if phy_ldpc_tx_supported() and (htCapInfo and 1) != 0:
      bufAddr = bufAddr or 64
    caps.maxAmsduLength = if (htCapInfo and 0x800'u16) != 0: 0x1EFF'u16 else: 0x0EFF'u16
    caps.maxBandwidth = sta.nssBwMax
    if caps.maxBandwidth > 3:
      assert_err("rc.c", "rc.c", 0x8CE.cint)
      return false
    if (caps.maxBandwidth == 0 and (htCapInfo and 0x20) != 0) or
       (caps.maxBandwidth == 1 and (htCapInfo and 0x40) != 0):
      caps.shortGi = 1
  else:
    caps.maxMcs = 0xFF
    caps.maxBandwidth = sta.nssBwMax
    if caps.maxBandwidth != 0:
      assert_err("rc.c", "rc.c", 0x8F2.cint)
      return false

  caps.sampleCount = rc_count_samples(stats)
  if caps.sampleCount == 0 or not rc_seed_rate_table(stats):
    assert_err("rc.c", "rc.c", 0x8F8.cint)
    return false

  let nRates = caps.sampleCount
  rcRetryStep(stats, 0).rateIdx = nRates - 1
  rcRetryStep(stats, 1).rateIdx = if nRates >= 2: nRates - 2 else: 0
  rcRetryStep(stats, 2).rateIdx = if nRates >= 3: nRates - 3 else: 0
  rcAmpduStats(stats).averageLengthQ16 = 0x10000
  caps.fixedRate = 0xFFFF
  discard rc_update_stats(stats, 1)
  when defined(bl808WifiNativeWlanCalibration):
    if vifChannelForIdx(ownerVifIdx).vifType == VIF_TYPE_STA:
      discard rcKeepCckFallbackReachable(stats)
  rcStatsCounters(stats).retryLimit = 5

  let policy = txPolicyAt(txPolicy)
  for retryPolicySlotIndex in 0 ..< 4:
    let retryIdx = rcRetryStep(stats, retryPolicySlotIndex).rateIdx
    policy.retryRate[retryPolicySlotIndex] =
      rcRateStats(stats, retryIdx.int).rateConfig.uint32 or 0x80000000'u32

  rcU32(stats, 0) = regRead(MACHW_TIMLO_REG)
  policy.status = 0xBADCAB1E'u32
  policy.bufferAddr = bufAddr
  policy.packetType = ((infoIdx.uint32 + 8) and 0xFF) shl 10
  policy.controlInfo = 0xFFFF0704'u32
  let ntx2 = phy_get_ntx()
  policy.bufferMask = if ntx2 >= 31: high(uint32) else: (1'u32 shl (ntx2.uint32 + 1)) - 1
  policy.edcaParam0 = 0x2200
  policy.edcaParam1 = cast[uint32](cast[uint](sta.vif))
  sta.txPolicyUpdateFlags[0] = sta.txPolicyUpdateFlags[0] or
    (StaTxPolicyUpdateRateControl or StaTxPolicyUpdateTxPower)
  true

proc rc_init*(staEntry: pointer) {.exportc, cdecl.} =
  discard rcTryInitStation(staEntry)

proc rc_install_trial(stats: pointer; sample: uint16; throughput: uint32; first: bool) =
  let best = rcRetryStep(stats, 0)
  let second = rcRetryStep(stats, 1)
  let backup = rcTrialBackup(stats)
  let control = rcTrialControl(stats)
  backup.rateIdx = second.rateIdx
  backup.throughput = second.throughput
  if first:
    second.rateIdx = best.rateIdx
    second.throughput = best.throughput
    best.rateIdx = sample
    best.throughput = throughput
    control.info = control.info and not 2'u8
  else:
    second.rateIdx = sample
    second.throughput = throughput
    control.info = control.info or 2'u8
  control.status = 2

proc rc_check*(staIdx: uint8) {.exportc, cdecl.} =
  ## Advance a rate trial and request a policy refresh when its chain changes.
  if staIdx > 4:
    return
  let sta = staInfoForIdx(staIdx)
  let stats = sta.rcStats
  if stats == nil:
    assert_err("rc_check", "rc_check", 0x822)
    return
  let nRates = rcRateCapabilities(stats).sampleCount.int
  if nRates == 0 or nRates > RC_MAX_RATE_ENTRIES:
    return
  let control = rcTrialControl(stats)
  let now = regRead(MACHW_TIMLO_REG)
  let remaining = RC_UPDATE_INTERVAL + rcU32(stats, 0) - now
  var changed = false
  if cast[int32](remaining) < 0:
    var previousRates: array[4, uint16]
    for step in 0 ..< previousRates.len:
      let index = rcRetryStep(stats, step).rateIdx.int
      if index < nRates:
        previousRates[step] = rcRateStats(stats, index).rateConfig
    changed = rc_update_stats(stats, 0) != 0
    # The vendor result compares indexes, but a sort can change the rates at
    # those indexes. Refresh the DMA policy when the resolved rates change.
    if not changed:
      for step, rate in previousRates:
        let index = rcRetryStep(stats, step).rateIdx.int
        if index < nRates and rate != rcRateStats(stats, index).rateConfig:
          changed = true
          break
    control.status = 0
    control.softwareRetryStep = 0
    control.info = control.info and not 0x10'u8
    rcU32(stats, 0) = regRead(MACHW_TIMLO_REG)

  if control.status in [1'u8, 3'u8]:
    let consumedSteps = if control.status == 1'u8: 3 else: 2
    for step in 0 ..< consumedSteps:
      if rcRetryStep(stats, step).rateIdx.int >= nRates:
        control.status = 0
        return

  if control.status == 1:
    if (control.info and 0x40) != 0:
      control.status = 0
    else:
      let bestIndex = rcRetryStep(stats, 0).rateIdx
      let secondIndex = rcRetryStep(stats, 1).rateIdx
      let probabilityIndex = rcRetryStep(stats, 2).rateIdx
      let ht = rcRateCapabilities(stats).formatMod > 1
      if ht:
        let meanLength = rcAmpduStats(stats).averageLengthQ16 shr 16
        control.sampleWait = (((meanLength + 8) * 2) and 0xFF).uint8
      else:
        let probability = rcRateStats(stats, bestIndex.int).probability
        control.sampleWait = if probability >= 0x1999 and probability <= 0xF333: 10 else: 5

      let sample = ((rcPrngNext() shr 16) mod nRates.uint32).uint16
      let sampleStats = rcRateStats(stats, sample.int)
      if sample == bestIndex or sample == secondIndex or sample == probabilityIndex or
          sampleStats.probability > 0xF333:
        control.status = 0
      else:
        let sampleDuration = rc_get_duration(sampleStats.rateConfig)
        var accepted = true
        var useFirst = false
        var throughput = 0'u32
        if not ht:
          let bestDuration = rc_get_duration(rcRateStats(stats, bestIndex.int).rateConfig)
          useFirst = sampleDuration <= bestDuration or sampleStats.sampleSkipped >= 20
        else:
          let secondDuration = rc_get_duration(rcRateStats(stats, secondIndex.int).rateConfig)
          let minimumSkipped = if sampleStats.oldProbAvailable == 0:
            (rcAmpduStats(stats).averageLengthQ16 shr 16) else: 32'u32
          var faster = sampleDuration < secondDuration
          if not faster:
            let bestNss = rc_get_nss(rcRateStats(stats, bestIndex.int).rateConfig)
            let sampleNss = rc_get_nss(sampleStats.rateConfig)
            if bestNss == 0 or sampleNss < bestNss:
              let probabilityDuration = rc_get_duration(rcRateStats(stats, probabilityIndex.int).rateConfig)
              faster = sampleDuration < probabilityDuration
          if not faster:
            if sampleStats.sampleSkipped.uint32 < minimumSkipped:
              accepted = false
            else:
              control.sampleSlow = ((control.sampleSlow.uint16 + 1) and 0xFF).uint8
              accepted = control.sampleSlow <= 2
              if control.sampleSlow > 15:
                control.sampleSlow = 15
          if accepted:
            throughput = rc_calc_tp(stats, sample.uint8)
            useFirst = (sampleStats.retryCount and 0xF) > 9 or
              sampleStats.sampleSkipped.uint32 >= minimumSkipped
        if accepted:
          when defined(bl808m0):
            let nextSerial = (rcTrialSerial[staIdx] + 1) and 0x3FFF_FFFF'u32
            rcTrialSerial[staIdx] = max(nextSerial, 1'u32)
          rc_install_trial(stats, sample, throughput, useFirst)
          changed = true
        else:
          control.status = 0

  elif control.status == 3:
    let backup = rcTrialBackup(stats)
    if backup.rateIdx.int >= nRates:
      control.status = 0
      return
    let best = rcRetryStep(stats, 0)
    let second = rcRetryStep(stats, 1)
    if (control.info and 2) == 0:
      best.rateIdx = second.rateIdx
      best.throughput = second.throughput
    second.rateIdx = backup.rateIdx
    second.throughput = backup.throughput
    backup.rateIdx = 0xFF
    backup.throughput = 0
    control.status = 0
    changed = true

  when defined(bl808WifiNativeWlanCalibration):
    if control.status == 0 and sta.instNbr < MAX_VIFS.uint8 and
        vifChannelForIdx(sta.instNbr).vifType == VIF_TYPE_STA and
        rcKeepCckFallbackReachable(stats):
      changed = true
  if changed:
    sta.txPolicyUpdateFlags[0] = sta.txPolicyUpdateFlags[0] or StaTxPolicyUpdateRateControl


proc rc_calc_tp*(stats: pointer; sampleIdx: uint8): uint32 {.exportc, cdecl.} =
  ## Calculate the vendor's Q16 throughput score for one rate-table entry.
  if stats == nil or sampleIdx.int >= RC_MAX_RATE_ENTRIES:
    return 0
  let rateEntry = rcRateEntry(stats, sampleIdx.uint16)
  let statsView = rcStatsCounters(stats)

  let probEwma = rateEntry.probEwma
  if probEwma <= 0x1998'u16:
    return 0
  let rateConfig = rateEntry.rateConfig

  # AMPDU overhead: added only when rate is NOT a CCK rate.
  var overhead: uint32 = 0
  if not is_cck_group(rateConfig.uint32):
    let ampduLen = statsView.avgAmpduLen
    if ampduLen == 0:
      return 0
    overhead = 0x35390'u32 div ampduLen.uint32

  let duration = rc_get_duration(rateConfig)
  if duration == 0:
    return 0
  let totalOverhead = overhead + duration
  let tpStep = (probEwma.uint32 * 1000'u32) div totalOverhead
  # Vendor MUL is 32-bit; WEXTI a0,a0,16 then removes the Q16 fraction.
  return (tpStep * 0xF4240'u32) shr 16

proc rcAccountCounters(staIdx: uint8; attemptCount, failureCount: uint32;
                       sentRates: ptr array[4, uint16]; finishTrial: bool;
                       sentSamples = 0'u16) =
  let saved = irqSave()
  defer: irqRestore(saved)
  inc nimFwDbgRcUpdateCalls
  nimFwDbgRcUpdateMeta = staIdx.uint32
  nimFwDbgRcUpdateArgs =
    (attemptCount and 0xFFFF'u32) or ((failureCount and 0xFFFF'u32) shl 16)

  if staIdx > 4:
    return

  let sta = staInfoForIdx(staIdx)

  # Check info_idx for validity (0xFF = uninitialized)
  if sta.instNbr == 0xFF:
    return

  let stats = sta.rcStats
  if stats == nil:
    assert_err("rc.c", "rc.c", 1998)
    return
  let counters = rcStatsCounters(stats)
  let sampleCount = rcRateCapabilities(stats).sampleCount

  if sampleCount == 0 or sampleCount > RC_MAX_RATE_ENTRIES.uint16 or
      failureCount > attemptCount:
    return
  if sentRates == nil:
    var pendingAttempts = attemptCount
    var pendingFailures = failureCount
    for retrySlot in counters.retrySlots:
      if pendingAttempts == 0:
        break
      if retrySlot.rateIdx >= sampleCount:
        return
      if pendingFailures <= 3:
        break
      pendingAttempts -= 4
      pendingFailures -= 4

  var attempts = attemptCount
  var failures = failureCount

  # Increment total counters
  counters.totalSuccess = counters.totalSuccess + 1
  counters.totalAttempts = counters.totalAttempts + 1

  for retrySlotIndex in 0 ..< counters.retrySlots.len:
    if attempts == 0:
      break

    let slotAttempts = if failures > 3: 4'u32 else: attempts
    let slotFailures = if failures > 3: 4'u32 else: failures
    var retryRateIndex = counters.retrySlots[retrySlotIndex].rateIdx
    if sentRates != nil:
      let sentRate = sentRates[][retrySlotIndex]
      let sample = (sentSamples shr (retrySlotIndex * 4)) and 0xF'u16
      retryRateIndex = sampleCount
      if sample <= sampleCount:
        if sample != 0 and
            (rcRateEntry(stats, sample - 1).rateConfig and 0x3FFF'u16) == sentRate:
          retryRateIndex = sample - 1
        else:
          # Untagged words and unique samples moved by sorting have no usable index.
          # Replacements and sorts with duplicates invalidate the generation instead.
          for index in 0'u16 ..< sampleCount:
            if (rcRateEntry(stats, index).rateConfig and 0x3FFF'u16) == sentRate:
              if retryRateIndex != sampleCount:
                retryRateIndex = sampleCount
                break
              retryRateIndex = index
    if retryRateIndex >= sampleCount:
      # A sample may have been replaced while the descriptor was queued.
      # Advance to the next physical slot without crediting a different rate.
      attempts -= slotAttempts
      failures -= slotFailures
      continue

    let retryRateEntry = rcRateEntry(stats, retryRateIndex)
    nimFwDbgRcUpdateSlot =
      retrySlotIndex.uint32 or
      (retryRateIndex.uint32 shl 8) or
      ((attempts and 0xFF'u32) shl 16) or
      ((failures and 0xFF'u32) shl 24)
    nimFwDbgRcUpdateEntry = pointerAddrU32(cast[pointer](retryRateEntry))
    nimFwDbgRcUpdateCounts =
      retryRateEntry.attempts.uint32 or (retryRateEntry.successes.uint32 shl 16)

    retryRateEntry.attempts += (slotAttempts and 0xFFFF'u32).uint16
    retryRateEntry.successes += ((slotAttempts - slotFailures) and 0xFFFF'u32).uint16
    attempts -= slotAttempts
    failures -= slotFailures

    # Successful attempts cannot outnumber all attempts.
    if retryRateEntry.attempts < retryRateEntry.successes:
      nimFwDbgRcUpdateFail =
        retryRateEntry.attempts.uint32 or
        (retryRateEntry.successes.uint32 shl 16) or
        ((retryRateIndex.uint32 and 0xFF'u32) shl 24) or
        ((retrySlotIndex.uint32 and 0xFF'u32) shl 28)
      assert_err("rc.c", "rc.c", 2040)
      return

  # Check update stage and advance state machine
  let stage = counters.updateStage
  if stage == 0:
    # Check retry limit
    let retryLimit = counters.retryLimit
    if retryLimit == 0:
      counters.updateStage = 1
    else:
      let newLimit = retryLimit - 1
      counters.retryLimit = newLimit
  elif stage == 2 and finishTrial:
    # Re-check with sta flags
    if (sta.txPolicyUpdateFlags[0] and StaTxPolicyUpdateRateControl) == 0:
      counters.updateStage = 3

proc rc_update_counters*(staIdx: uint8; attemptCount, failureCount: uint32;
                         txAmpdu, retryRequired: bool) {.exportc, cdecl.} =
  ## Vendor ABI for reports that do not carry a submitted rate policy.
  discard txAmpdu
  discard retryRequired
  rcAccountCounters(staIdx, attemptCount, failureCount, nil, not defined(bl808m0))

proc rc_get_duration*(rateConfig: uint16): uint32 {.exportc, cdecl.} =
  ## Return the reference duration in nanoseconds for this packed rate.
  let formatMod = (rateConfig shr 11) and 7
  let rateIdx = rc_get_mcs_index(rateConfig).int
  if (formatMod and 6) == 0:
    if rateIdx < 4:
      let preamble = ((rateConfig shr 10) and 1).int
      return RcDurationCck[rateIdx * 2 + preamble]
    let ofdmIdx = rateIdx - 4
    if ofdmIdx >= RcDurationNonHt.len:
      return 0
    return RcDurationNonHt[ofdmIdx]
  if formatMod notin [2'u16, 3'u16]:
    return 0
  let bandwidth = ((rateConfig shr 7) and 3).int
  let guardInterval = ((rateConfig shr 9) and 1).int
  let durationIdx = rateIdx * 8 + bandwidth * 2 + guardInterval
  if durationIdx >= RcDurationHtAmpdu.len:
    return 0
  RcDurationHtAmpdu[durationIdx] div (rc_get_nss(rateConfig).uint32 + 1)

proc rc_update_bw_nss_max*(staIdx: uint8, maxBandwidth: uint8, maxNss: uint8) {.exportc, cdecl.} =
  ## Update bandwidth/NSS limits and rebuild automatic-rate samples if needed.
  if staIdx >= STA_INFO_TAB_ENTRIES.uint8:
    return
  let sta = staInfoForIdx(staIdx)
  let rcStats = sta.rcStats
  if rcStats == nil:
    assert_err("rc.c", "rc.c", 0x95D.cint)
    return

  if maxBandwidth > 3:
    assert_err("rc.c", "rc.c", 0x963.cint)
    return
  if maxNss > 7:
    assert_err("rc.c", "rc.c", 0x965.cint)
    return
  let previousBandwidth = rcU8(rcStats, RCS_NO_SS)
  let previousNss = rcU8(rcStats, RCS_GROUP_CNT)
  if previousBandwidth == maxBandwidth and previousNss == maxNss:
    return
  rcU8(rcStats, RCS_NO_SS) = maxBandwidth
  rcU8(rcStats, RCS_GROUP_CNT) = maxNss

  # Check if rate table needs re-initialization: sample_idx == 0xFFFF
  let sampleIdx = rcU16(rcStats, RCS_SAMPLE_IDX)
  if sampleIdx != 0xFFFF'u16:
    return

  if not rc_seed_rate_table(rcStats):
    rcU8(rcStats, RCS_NO_SS) = previousBandwidth
    rcU8(rcStats, RCS_GROUP_CNT) = previousNss
    return
  when defined(bl808m0):
    rcInvalidateTrialTag(staIdx)
  let nRates = rcU16(rcStats, RCS_N_RATES)

  # Invalidate probability/retry estimates, preserving packet counters.
  for rateEntryIndex in 0 ..< nRates.int:
    rcClearRateEntryTransientStats(rcStats, rateEntryIndex.uint16)

  # Sort by throughput and rebuild retry chain
  var tpArray: array[RC_MAX_RATE_ENTRIES, uint32]
  rc_sort_samples_tp(rcStats, addr tpArray[0])
  rc_update_retry_chain(rcStats, addr tpArray[0])

  # Re-compute staEntry and mark the TX policy retry chain stale.
  sta.txPolicyUpdateFlags[0] = sta.txPolicyUpdateFlags[0] or StaTxPolicyUpdateRateControl

proc rc_update_preamble_type*(staIdx: uint8, preambleType: uint8) {.exportc, cdecl.} =
  ## Apply the preamble encoding and refresh automatic-rate samples.
  if staIdx >= STA_INFO_TAB_ENTRIES.uint8 or preambleType > 1:
    return
  let sta = staInfoForIdx(staIdx)
  let stats = sta.rcStats
  if stats == nil:
    assert_err("rc.c", "rc.c", 0x9A2.cint)
    return

  let caps = rcRateCapabilities(stats)
  if caps.preambleType == preambleType:
    return

  let fixedRate = caps.fixedRate
  let nRates = caps.sampleCount.int
  if fixedRate == 0xFFFF'u16 and preambleType != 0 and
      (nRates == 0 or nRates > RC_MAX_RATE_ENTRIES):
    return
  caps.preambleType = preambleType
  when defined(bl808m0):
    rcInvalidateTrialTag(staIdx)
  if fixedRate != 0xFFFF'u16 or preambleType == 0:
    return

  when defined(bl808m0):
    rcInvalidateRateSamples(stats)
  var compactSamples = false
  for rateEntryIndex in 0 ..< nRates:
    let preambleRateEntry = rcRateStats(stats, rateEntryIndex)
    var rateConfig = preambleRateEntry.rateConfig
    if is_cck_group(rateConfig.uint32):
      rateConfig = rateConfig or 0x0400'u16
      # Keep the lowest-rate fallback and ignore the entry being converted,
      # but resolve collisions against the entire remaining table.
      var duplicate = false
      if rateEntryIndex != 0:
        for otherIndex in 0 ..< nRates:
          if otherIndex != rateEntryIndex and
              rcRateStats(stats, otherIndex).rateConfig == rateConfig:
            duplicate = true
            break
      if duplicate:
        let randomRate = rc_pick_non_duplicate_rate(stats)
        if randomRate == 0xFFFF'u16:
          compactSamples = true
        else:
          rateConfig = randomRate
      rcClearRateEntryTransientStats(stats, rateEntryIndex.uint16)
      preambleRateEntry.rateConfig = rateConfig

  if compactSamples:
    # Preamble conversion can leave fewer distinct rates than samples.
    var retained = 0
    for rateEntryIndex in 0 ..< nRates:
      let entry = rcRateStats(stats, rateEntryIndex)
      var duplicate = false
      for previous in 0 ..< retained:
        if rcRateStats(stats, previous).rateConfig == entry.rateConfig:
          duplicate = true
          break
      if not duplicate:
        if retained != rateEntryIndex:
          rcRateStats(stats, retained)[] = entry[]
        inc retained
    caps.sampleCount = retained.uint16
    for unused in retained ..< nRates:
      rcSetRateConfig(stats, unused, 0xFFFF'u16)

  # Rebuild rate ordering and retry chain
  var tpArray: array[RC_MAX_RATE_ENTRIES, uint32]
  rc_sort_samples_tp(stats, addr tpArray[0])
  rc_update_retry_chain(stats, addr tpArray[0])

  # Mark STA for RC update
  sta.txPolicyUpdateFlags[0] = sta.txPolicyUpdateFlags[0] or StaTxPolicyUpdateRateControl

proc rc_init_bcmc_rate*(staEntry: pointer, band: uint32) {.exportc, cdecl.} =
  ## Initialize broadcast/multicast rate.
  ## From blob (12 instrs): a0=sta_info_tag pointer, a1=band (rate index).
  ## Loads TX policy from sta+320, supported rates from sta+332.
  ## Builds rate config: band | (suppRates & 0x400 if band <= 3) | 0x20000000.
  ## Writes to 4 retry slots at txPolicy offsets 20, 24, 28, 32.
  if staEntry == nil or band > 11:
    return
  let sta = staInfoAt(staEntry)
  let txPolicy = sta.txPolicy
  if txPolicy == nil:
    return
  let policy = txPolicyAt(txPolicy)
  let suppRates = sta.supportedRatesBitmap
  var rateConfig = band
  # Conditionally include CCK rate bit if band <= 3
  if band <= 3:
    rateConfig = rateConfig or (suppRates.uint32 and 0x400'u32)
  rateConfig = rateConfig or 0x20000000'u32  # format mod
  for retry in mitems(policy.retryRate):
    retry = rateConfig

proc rc_check_fixed_rate_config*(stats: pointer, rateConfig: uint16): bool {.exportc, cdecl.} =
  ## Validate a packed rate without changing the rate-control state.
  if stats == nil:
    return false
  let caps = rcRateCapabilities(stats)
  let formatMod = (rateConfig shr 11) and 7
  if formatMod > caps.formatMod.uint16:
    return false
  if caps.formatMod == 4 and formatMod != 4:
    return false

  if (formatMod and 6) == 0:
    if caps.formatMod in [2'u8, 3'u8] and caps.lowestLegacyRate > 3:
      return false
    if (rateConfig and 0x0400) == 0 and caps.preambleType == 1:
      return false
  else:
    if (rateConfig and 0x0200) != 0 and caps.shortGi == 0:
      return false
    let bandwidth = (rateConfig shr 7) and 3
    if bandwidth > caps.maxBandwidth.uint16:
      return false
    if rc_get_nss(rateConfig) > caps.maxNss:
      return false

  rc_check_valid_rate(stats, rateConfig) != 0

# RC internal helpers called by initialization and rate validation.
proc rc_get_mcs_index*(rateConfig: uint16): uint8 {.exportc, cdecl.} =
  ## Extract MCS index from packed rate_config.
  ## Legacy (bits[12:11]==0): return bits[6:0]
  ## HT/VHT: return bits[2:0] (MCS within NSS group)
  let fmtMod = (rateConfig shr 11) and 0x6
  if fmtMod == 0:
    return (rateConfig and 0x7F).uint8
  else:
    let nss = ((rateConfig shr 11) and 0x6).uint8
    if nss < 2:
      return 0
    let nssEncodingOffset = (nss - 2) and 0xFF
    if nssEncodingOffset > 1:
      return 0
    return (rateConfig and 0x7).uint8

proc rc_get_nss*(rateConfig: uint16): uint8 {.exportc, cdecl, noinline.} =
  ## Extract the zero-based spatial-stream count from rate_config.
  let formatMod = (rateConfig shr 11) and 7
  if formatMod notin [2'u16, 3'u16]:
    return 0
  return ((rateConfig shr 3) and 3).uint8

proc rc_check_valid_rate*(stats: pointer, rateConfig: uint16): uint8 {.exportc, cdecl.} =
  ## Check the station's legacy or HT rate bitmap.
  if stats == nil:
    return 0
  let formatMod = (rateConfig shr 11) and 7
  if (formatMod and 6) == 0:
    let legacyRateBitIndex = rc_get_mcs_index(rateConfig)
    if legacyRateBitIndex >= 16:
      return 0
    let rateMap = rcU16(stats, RCS_RATE_MAP)
    return ((rateMap shr legacyRateBitIndex) and 1).uint8
  # The archive treats formats above HT as valid without a bitmap lookup.
  if formatMod notin [2'u16, 3'u16]:
    return 1
  let nssIdx = rc_get_nss(rateConfig)
  let mcsIdx = rc_get_mcs_index(rateConfig)
  let bitmap = rcU8(stats, RCS_RATE_BITMAP + nssIdx.int)
  return ((bitmap shr mcsIdx) and 1).uint8

proc rc_check_rate_duplicated*(stats: pointer, rateConfig: uint16): uint8 {.exportc, cdecl.} =
  ## Check if rateConfig already exists in the rate table.
  ## Returns 1 if duplicated, 0 if not.
  if stats == nil:
    return 0
  let nRates = rcU16(stats, RCS_N_RATES)
  if nRates > RC_MAX_RATE_ENTRIES.uint16:
    return 0
  for rateEntryIndex in 0 ..< nRates.int:
    if rcRateConfig(stats, rateEntryIndex) == rateConfig:
      return 1
  return 0

proc rc_get_initial_rate_config*(stats: pointer): uint16 {.exportc, cdecl.} =
  ## Seed the highest negotiated rate, preserving the vendor's field layout.
  if stats == nil:
    return 0xFFFF'u16
  let caps = rcRateCapabilities(stats)
  if caps.formatMod <= 1:
    if caps.highestLegacyRate >= 16 or caps.preambleType > 1:
      return 0xFFFF'u16
    return (caps.formatMod.uint16 shl 11) or (caps.preambleType.uint16 shl 10) or
      caps.highestLegacyRate.uint16
  if caps.formatMod notin [2'u8, 3'u8]:
    return 0
  if caps.maxNss.int >= caps.mcsBitmaps.len or caps.maxBandwidth > 3 or caps.shortGi > 1:
    return 0xFFFF'u16
  let bitmap = caps.mcsBitmaps[caps.maxNss.int]
  if bitmap == 0:
    return 0xFFFF'u16
  (caps.formatMod.uint16 shl 11) or (caps.shortGi.uint16 shl 9) or
    (caps.maxBandwidth.uint16 shl 7) or (caps.maxNss.uint16 shl 3) or
    rcHighestBit(bitmap).uint16

proc rc_get_lowest_rate_config*(stats: pointer): uint16 {.exportc, cdecl.} =
  ## HT falls back to 1 Mbps when available, otherwise to the lowest HT MCS.
  if stats == nil:
    return 0xFFFF'u16
  let caps = rcRateCapabilities(stats)
  if caps.formatMod > 3:
    return 0
  if caps.lowestLegacyRate == 0:
    return 0x400'u16
  if caps.formatMod <= 1:
    if caps.lowestLegacyRate >= 16:
      return 0xFFFF'u16
    return caps.lowestLegacyRate.uint16
  when defined(bl808WifiNativeWlanCalibration):
    if caps.maxNss == 0:
      for mcs in 0 ..< 8:
        if (caps.mcsBitmaps[0] and (1'u8 shl mcs)) != 0:
          return (caps.formatMod.uint16 shl 11) or mcs.uint16
      return 0xFFFF'u16
  caps.formatMod.uint16 shl 11

proc rc_new_random_rate*(stats: pointer): uint16 {.exportc, cdecl.} =
  ## One PRNG draw chooses legacy fallback or the negotiated HT fields.
  if stats == nil:
    return 0xFFFF'u16
  let randomBits = rcPrngNext() shr 16
  let caps = rcRateCapabilities(stats)
  let formatBits = caps.formatMod.uint16 shl 11
  if caps.formatMod > 3:
    return formatBits

  let legacyFallback = caps.formatMod > 1 and caps.lowestLegacyRate <= 3 and
    (randomBits and 0x800) != 0
  if caps.formatMod <= 1 or legacyFallback:
    let lowest = caps.lowestLegacyRate.uint32
    let highest = caps.highestLegacyRate.uint32
    if lowest > highest or highest >= 16:
      return 0xFFFF'u16
    var rateIndex = lowest + (randomBits and 0x7F) mod (highest - lowest + 1)
    if ((caps.legacyRateMap shr rateIndex) and 1) == 0:
      rateIndex = highest
      if ((caps.legacyRateMap shr rateIndex) and 1) == 0:
        return 0xFFFF'u16
    var rate = (if legacyFallback: 0'u16 else: formatBits) or rateIndex.uint16
    if rateIndex == 0:
      return rate or 0x400'u16
    # HT fallback carries bit 10 for every nonzero legacy index.
    if legacyFallback or rateIndex <= 3:
      rate = rate or (caps.preambleType.uint16 shl 10) or
        (randomBits and 0x400).uint16
    return rate

  if caps.maxNss.int >= caps.mcsBitmaps.len or caps.maxBandwidth > 3:
    return 0xFFFF'u16
  let nss = ((randomBits shr 3) and 3) mod (caps.maxNss.uint32 + 1)
  let bitmap = caps.mcsBitmaps[nss.int]
  if bitmap == 0:
    return 0xFFFF'u16
  var mcs = (randomBits and 7) mod (caps.maxMcs.uint32 + 1)
  if ((bitmap shr mcs) and 1) == 0:
    mcs = rcHighestBit(bitmap).uint32
  let shortGi = ((randomBits shr 9) and 1) mod (caps.shortGi.uint32 + 1)
  let minBandwidth = if caps.maxBandwidth == 0: 0'u32 else: caps.maxBandwidth.uint32 - 1
  let bandwidth = minBandwidth + ((randomBits shr 7) and 3) mod
    (caps.maxBandwidth.uint32 - minBandwidth + 1)
  formatBits or (nss.uint16 shl 3) or mcs.uint16 or
    (shortGi.uint16 shl 9) or (bandwidth.uint16 shl 7)

proc rc_update_retry_chain*(stats: pointer, param: pointer) {.exportc, cdecl.} =
  ## Build [best throughput, second throughput, best probability, lowest].
  ## param is the uint32 throughput array corresponding to the sorted samples.
  if stats == nil or param == nil:
    return
  let nRates = rcU16(stats, RCS_N_RATES).int
  if nRates == 0 or nRates > RC_MAX_RATE_ENTRIES:
    return
  let tp = rcThroughputArray(param)
  let flags = rcU8(stats, RCS_FLAGS)
  var bestIdx = 0
  var bestThroughput = 0'u32
  var nextRank = 1
  if (flags and 0x04) != 0 or tp[nRates - 1] >= tp[0]:
    bestIdx = nRates - 1
    bestThroughput = tp[bestIdx]
    nextRank = 2
  rcRetryStep(stats, 0).rateIdx = bestIdx.uint16
  rcRetryStep(stats, 0).throughput = bestThroughput

  if not is_cck_group(rcRateStats(stats, bestIdx).rateConfig.uint32):
    for rateEntryIndex in 0 ..< nRates - 1:
      let rateStats = rcRateStats(stats, rateEntryIndex)
      if is_cck_group(rateStats.rateConfig.uint32):
        rateStats.rateAllowed = 0
    rcRateStats(stats, bestIdx).rateAllowed = 1

  var secondIdx = bestIdx
  var secondThroughput = bestThroughput
  while true:
    let candidateIdx = nRates - nextRank
    inc nextRank
    if candidateIdx <= 0:
      break
    if rcRateStats(stats, candidateIdx).rateAllowed != 0:
      secondIdx = candidateIdx
      secondThroughput = tp[candidateIdx]
      break
  rcRetryStep(stats, 1).rateIdx = secondIdx.uint16
  rcRetryStep(stats, 1).throughput = secondThroughput

  var bestProbIdx = nRates - nextRank
  while bestProbIdx > 0 and rcRateStats(stats, bestProbIdx).rateAllowed == 0:
    dec bestProbIdx
  if bestProbIdx <= 0:
    bestProbIdx = secondIdx
  var bestProbability = rcRateStats(stats, bestProbIdx).probability
  var bestProbThroughput = tp[bestProbIdx]
  for rateEntryIndex in 0 ..< secondIdx:
    let rateStats = rcRateStats(stats, rateEntryIndex)
    if rateStats.rateAllowed == 0 or rateEntryIndex == bestIdx:
      continue
    let probability = rateStats.probability
    if (probability > 0xF332'u16 and tp[rateEntryIndex] >= bestProbThroughput) or
       (probability <= 0xF332'u16 and probability >= bestProbability):
      bestProbIdx = rateEntryIndex
      bestProbability = probability
      bestProbThroughput = tp[rateEntryIndex]
  rcRetryStep(stats, 2).rateIdx = bestProbIdx.uint16
  rcRetryStep(stats, 2).throughput = tp[bestProbIdx]
  rcRetryStep(stats, 3).rateIdx = 0
  rcRetryStep(stats, 3).throughput = tp[0]

proc rc_get_new_sample_rates(stats: pointer): array[6, uint16] =
  ## Candidate priority: random, other GI, then neighbors of best and second-best.
  for candidate in result.mitems:
    candidate = 0xFFFF'u16
  let best = rcRateStats(stats, rcRetryStep(stats, 0).rateIdx.int).rateConfig
  let second = rcRateStats(stats, rcRetryStep(stats, 1).rateIdx.int).rateConfig
  result[0] = rc_new_random_rate(stats)
  if ((best shr 11) and 6) != 0 and rcU8(stats, RCS_SHORT_GI) == 1:
    result[1] = best xor 0x200'u16
  let nextBest = rc_set_next_mcs_index(stats, best)
  if nextBest != best and rc_check_valid_rate(stats, nextBest) != 0:
    result[2] = nextBest
  let previousBest = rc_set_previous_mcs_index(stats, best)
  if previousBest != best and rc_check_valid_rate(stats, previousBest) != 0:
    result[3] = previousBest
  let nextSecond = rc_set_next_mcs_index(stats, second)
  if nextSecond != second and rc_check_valid_rate(stats, nextSecond) != 0:
    result[4] = nextSecond
  let previousSecond = rc_set_previous_mcs_index(stats, second)
  if previousSecond != second and rc_check_valid_rate(stats, previousSecond) != 0:
    result[5] = previousSecond

proc rc_get_new_samples(stats: pointer) =
  let candidates = rc_get_new_sample_rates(stats)
  let nRates = rcU16(stats, RCS_N_RATES).int
  var candidateIndex = 0
  var rateEntryIndex = 1
  when defined(bl808m0):
    var invalidated = false
  while rateEntryIndex < nRates:
    let rateStats = rcRateStats(stats, rateEntryIndex)
    let protectedRate = rateEntryIndex == rcRetryStep(stats, 0).rateIdx.int or
      rateEntryIndex == rcRetryStep(stats, 1).rateIdx.int or
      rateEntryIndex == rcRetryStep(stats, 2).rateIdx.int
    let recentlySuccessful = rateStats.probability >= 0x8000'u16 and
      rateStats.sampleSkipped <= 10
    if protectedRate or recentlySuccessful or candidateIndex == candidates.len:
      inc rateEntryIndex
    else:
      let candidate = candidates[candidateIndex]
      inc candidateIndex
      if candidate != 0xFFFF'u16 and rc_check_rate_duplicated(stats, candidate) == 0:
        when defined(bl808m0):
          if not invalidated:
            rcInvalidateRateSamples(stats)
            invalidated = true
        rateStats.rateConfig = candidate
        rateStats.probability = 0
        rateStats.oldProbAvailable = 0
        inc rateEntryIndex
    # Rejected candidates retry the same slot, but still consume a candidate.
    rateStats.attempts = 0
    rateStats.successes = 0
  rcRateStats(stats, 0).attempts = 0
  rcRateStats(stats, 0).successes = 0

proc rc_update_stats*(stats: pointer, init: uint8): uint8 {.exportc, cdecl.} =
  ## Recalculate automatic rates or apply/update the requested fixed rate.
  if stats == nil:
    return 0
  let nRates = rcU16(stats, RCS_N_RATES).int
  if nRates == 0 or nRates > RC_MAX_RATE_ENTRIES:
    return 0
  var previousIndexes: array[4, uint16]
  for step in 0 ..< previousIndexes.len:
    previousIndexes[step] = rcRetryStep(stats, step).rateIdx

  let ampdu = rcAmpduStats(stats)
  if ampdu.ampduPackets != 0:
    # Preserve the vendor's signed RV32 DIV and wrapping Q16 EWMA arithmetic.
    let scaledLength = cast[uint32](cast[int32](ampdu.ampduLength.uint32 shl 16) div
      ampdu.ampduPackets.int32)
    ampdu.averageLengthQ16 = (ampdu.averageLengthQ16 * 96'u32 +
      (scaledLength shl 5)) shr 7
    ampdu.ampduLength = 0
    ampdu.ampduPackets = 0

  let counters = rcStatsCounters(stats)
  counters.slowRateCount = 0
  for rateEntryIndex in 0 ..< nRates:
    let rateStats = rcRateStats(stats, rateEntryIndex)
    rateStats.retryCount = 0
    rateStats.rateAllowed = 1

  var changed = false
  if counters.fixedRate == 0xFFFF'u16:
    var tpArray: array[RC_MAX_RATE_ENTRIES, uint32]
    for rateEntryIndex in 0 ..< nRates:
      rc_calc_prob_ewma(rcRateStats(stats, rateEntryIndex))
      tpArray[rateEntryIndex] = rc_calc_tp(stats, rateEntryIndex.uint8)
    rc_sort_samples_tp(stats, addr tpArray[0])
    rc_update_retry_chain(stats, addr tpArray[0])
    if init == 0:
      if nRates == RC_MAX_RATE_ENTRIES:
        rc_get_new_samples(stats)
      else:
        for rateEntryIndex in 0 ..< nRates:
          let rateStats = rcRateStats(stats, rateEntryIndex)
          rateStats.attempts = 0
          rateStats.successes = 0
  elif (counters.flags and 0x20) != 0:
    var fixedIndex = 0
    while fixedIndex < nRates and
        rcRateStats(stats, fixedIndex).rateConfig != counters.fixedRate:
      inc fixedIndex
    if fixedIndex == nRates:
      fixedIndex = nRates - 1
      let fixedStats = rcRateStats(stats, fixedIndex)
      when defined(bl808m0):
        rcInvalidateRateSamples(stats)
      fixedStats.rateConfig = counters.fixedRate
      fixedStats.probability = 0
    for step in 0 ..< 3:
      rcRetryStep(stats, step).rateIdx = fixedIndex.uint16
      rcRetryStep(stats, step).throughput = 0
    for rateEntryIndex in 0 ..< nRates:
      let rateStats = rcRateStats(stats, rateEntryIndex)
      rateStats.attempts = 0
      rateStats.successes = 0
    counters.flags = (counters.flags and not 0x60'u8) or 0x40'u8
    changed = true
  else:
    let currentIndex = (rcRetryStep(stats, 0).rateIdx and 0x00FF'u16).int
    if currentIndex >= nRates:
      return 0
    let currentStats = rcRateStats(stats, currentIndex)
    rc_calc_prob_ewma(currentStats)
    currentStats.attempts = 0
    currentStats.successes = 0
    rcRateStats(stats, 0).attempts = 0
    rcRateStats(stats, 0).successes = 0

  for step in 0 ..< previousIndexes.len:
    if previousIndexes[step] != rcRetryStep(stats, step).rateIdx:
      changed = true
  changed.uint8

proc rc_set_previous_mcs_index*(stats: pointer, rateConfig: uint16): uint16 {.exportc, cdecl.} =
  ## Produce the lower neighbor; callers validate support separately.
  if stats == nil:
    return rateConfig
  let formatMod = (rateConfig shr 11) and 7
  let mcsIdx = rc_get_mcs_index(rateConfig)
  if (formatMod and 6) == 0:
    let loIdx = rcU8(stats, RCS_LOWEST_IDX)
    if mcsIdx <= loIdx:
      return rateConfig
    return (rateConfig and 0xFF80'u16) or (mcsIdx - 1).uint16
  if formatMod notin [2'u16, 3'u16] or mcsIdx == 0:
    return rateConfig
  var previous = (rateConfig and 0xFFF8'u16) or (mcsIdx - 1).uint16
  if rcU8(stats, RCS_SHORT_GI) != 0:
    previous = previous or 0x200'u16
  previous

proc rc_set_next_mcs_index*(stats: pointer, rateConfig: uint16): uint16 {.exportc, cdecl.} =
  ## Advance to the adjacent supported MCS in the same NSS group.
  if stats == nil:
    return rateConfig
  let formatMod = (rateConfig shr 11) and 7
  let mcsIdx = rc_get_mcs_index(rateConfig)
  if (formatMod and 6) == 0:
    let hiIdx = rcU8(stats, RCS_HIGHEST_IDX)
    if mcsIdx >= hiIdx:
      return rateConfig
    let nextIdx = mcsIdx + 1
    let rateMap = rcU16(stats, RCS_RATE_MAP)
    if ((rateMap shr nextIdx) and 1) != 0:
      return (rateConfig and 0xFF80'u16) or nextIdx.uint16
    return rateConfig
  if formatMod notin [2'u16, 3'u16] or mcsIdx >= rcU8(stats, RCS_MAX_NSS_MCS):
    return rateConfig
  # The legacy and HT increments in rc.o are on separate branches.
  let nextMcs = mcsIdx + 1
  if nextMcs > 7:
    return rateConfig
  let nssIdx = rc_get_nss(rateConfig)
  let bitmap = rcU8(stats, RCS_RATE_BITMAP + nssIdx.int)
  if ((bitmap shr nextMcs) and 1) == 0:
    return rateConfig
  var next = (rateConfig and 0xFFF8'u16) or nextMcs.uint16
  if rcU8(stats, RCS_SHORT_GI) != 0:
    next = next or 0x200'u16
  next

proc rc_sort_samples_tp*(stats: pointer, tpArray: pointer) {.exportc, cdecl.} =
  ## Keep the lowest-rate entry fixed; stably sort the rest by ascending TP.
  if stats == nil or tpArray == nil:
    return
  let nRates = rcU16(stats, RCS_N_RATES).int
  if nRates <= 2 or nRates > RC_MAX_RATE_ENTRIES:
    return
  let tp = rcThroughputArray(tpArray)
  var sortPassLimit = nRates - 1
  when defined(bl808m0):
    var checkedDuplicates = false
  while sortPassLimit > 1:
    var lastSwap = 0
    for throughputSortIndex in 1 ..< sortPassLimit:
      let currentThroughput = tp[throughputSortIndex]
      let nextThroughput = tp[throughputSortIndex + 1]
      if currentThroughput > nextThroughput:
        when defined(bl808m0):
          if not checkedDuplicates:
            # Unique encodings can still identify their samples after a reorder.
            if rcHasDuplicateSampleEncoding(stats, nRates):
              rcInvalidateRateSamples(stats)
            checkedDuplicates = true
        let currentRateEntry = rcRateStats(stats, throughputSortIndex)
        let nextRateEntry = rcRateStats(stats, throughputSortIndex + 1)
        swap(currentRateEntry[], nextRateEntry[])
        swap(tp[throughputSortIndex], tp[throughputSortIndex + 1])
        lastSwap = throughputSortIndex
    sortPassLimit = lastSwap

proc rc_calc_prob_ewma*(entry: pointer) {.exportc, cdecl.} =
  ## Calculate probability EWMA for a single rate entry.
  ## Entry layout: +0=attempts(u16), +2=successes(u16), +4=prob_ewma(u16),
  ##               +8=cleared(u8), +9=initialized(u8)
  let attempts = rcU16(entry, 0)
  if attempts == 0:
    # No data: increment idle counter at +8, capped at 255
    let idle = rcU8(entry, 8)
    if idle < 255:
      rcU8(entry, 8) = idle + 1
    return

  let successes = rcU16(entry, 2)
  let initialized = rcU8(entry, 9)

  # Clear tracking byte
  rcU8(entry, 8) = 0

  # Calculate probability: (successes << 16) / attempts
  let prob = (successes.uint32 shl 16) div attempts.uint32

  if initialized == 0:
    # Q16 probabilities use 0xFFFF for 100%, not a wrapping 0x10000.
    rcU16(entry, 4) = if prob == 0: 0'u16 else: (prob - 1).uint16
  else:
    # EWMA: new = (old * 96 + new * 32) / 128
    let oldProb = rcU16(entry, 4).uint32
    let ewma = (oldProb * 96 + (prob shl 5)) shr 7
    rcU16(entry, 4) = ewma.uint16

  # Mark as initialized
  rcU8(entry, 9) = 1
