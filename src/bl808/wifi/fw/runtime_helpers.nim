# =============================================================================
# Helper: interrupt save/restore (from disassembly: csrrci/csrsi mstatus,8)
# =============================================================================
template irqSave(): uint32 =
  ## Templated so the `csrrci mstatus, 8` emits inline at the call site,
  ## matching blob (which never wraps the CSR op in a call). Previously a
  ## {.inline.} proc — GCC kept a standalone symbol and every caller
  ## picked up an extra `irqRestore__wifi95fw_u1904`-style call that
  ## isn't in the blob.
  block:
    var irqPrev {.gensym.}: uint32
    # Keep shared-memory accesses inside the interrupt-protected region.
    {.emit: ["asm volatile(\"csrrci %0, mstatus, 8\" : \"=r\"(", irqPrev, ") :: \"memory\");"].}
    irqPrev

template irqRestore(prev: uint32) =
  if (prev and 8) != 0:
    {.emit: ["asm volatile(\"csrsi mstatus, 8\" ::: \"memory\");"].}

proc wifiDmaStoreLink(desc: pointer; offset: uint; successor: pointer) {.inline.} =
  # Live descriptor links are aligned RV32 words even in packed overlays.
  # A packed-field assignment can expose a partially written DMA address.
  let slot = cast[pointer](cast[uint](desc) + offset)
  when sizeof(pointer) == sizeof(uint32):
    volatileStore(cast[ptr uint32](slot), cast[uint32](successor))
  else:
    # Host fixtures can have pointer-sized fields at unaligned offsets.
    var value = successor
    copyMem(slot, addr value, sizeof(value))

proc macTimeNow(): uint32 {.inline.} =
  ## Read current MAC HW timestamp.
  regRead(MACHW_TIMLO_REG)

# =============================================================================
# RC helper: typed access to rc_sta_stats fields from raw byte pointer
# =============================================================================
template rcU8(base: pointer, off: int): var uint8 =
  cast[ptr uint8](cast[uint](base) + off.uint)[]

template rcU16(base: pointer, off: int): var uint16 =
  cast[ptr uint16](cast[uint](base) + off.uint)[]

template rcU32(base: pointer, off: int): var uint32 =
  cast[ptr uint32](cast[uint](base) + off.uint)[]

template rcPtr(base: pointer, off: int): var pointer =
  cast[ptr pointer](cast[uint](base) + off.uint)[]

template rcPrngNext(): uint32 =
  ## Advance the LCG PRNG and return new state. Templated (not a {.inline.}
  ## proc) to force Nim-level inlining so the call graph matches blob,
  ## which emits the LCG arithmetic inline at every use site.
  rcPrngState = rcPrngState * RC_PRNG_MULT + RC_PRNG_INCR
  rcPrngState

proc rcRateEntryPtr(stats: pointer, rateEntryIndex: int): pointer {.inline.} =
  ## Legacy counter overlay base, four bytes before the actual rate record.
  cast[pointer](cast[uint](stats) + (rateEntryIndex * RC_RATE_ENTRY_SIZE).uint)

template rcRateEntryAt(p: pointer): ptr RcRateEntryView =
  cast[ptr RcRateEntryView](p)

template rcRateEntry(stats: pointer, rateEntryIndex: uint16): ptr RcRateEntryView =
  cast[ptr RcRateEntryView](cast[uint](stats) + rateEntryIndex.uint * RC_RATE_ENTRY_SIZE.uint)

template rcRateStats(stats: pointer, rateEntryIndex: int): ptr RcRateStatsView =
  cast[ptr RcRateStatsView](cast[uint](stats) + 4 + rateEntryIndex.uint * RC_RATE_ENTRY_SIZE.uint)

template rcRetryStep(stats: pointer, stepIndex: int): ptr RcRetryStepView =
  cast[ptr RcRetryStepView](cast[uint](stats) + 124 + stepIndex.uint * sizeof(RcRetryStepView).uint)

template rcTrialBackup(stats: pointer): ptr RcRetryStepView =
  cast[ptr RcRetryStepView](cast[uint](stats) + 156)

template rcTrialControl(stats: pointer): ptr RcTrialControlView =
  cast[ptr RcTrialControlView](cast[uint](stats) + 172)

template rcAmpduStats(stats: pointer): ptr RcAmpduStatsView =
  cast[ptr RcAmpduStatsView](cast[uint](stats) + 164)

template rcRateCapabilities(stats: pointer): ptr RcRateCapabilitiesView =
  cast[ptr RcRateCapabilitiesView](cast[uint](stats) + 177)

template rcThroughputArray(tpArray: pointer): ptr UncheckedArray[uint32] =
  cast[ptr UncheckedArray[uint32]](tpArray)

template rcStatsCounters(stats: pointer): ptr RcStatsCounterView =
  cast[ptr RcStatsCounterView](stats)

proc rcClearRateEntryTransientStats(stats: pointer; rateEntryIndex: uint16) {.inline.} =
  let rateStats = rcRateStats(stats, rateEntryIndex.int)
  rateStats.probability = 0
  rateStats.oldProbAvailable = 0
  rateStats.retryCount = 0
  rateStats.rateAllowed = 1

proc rcRateConfig(stats: pointer, rateEntryIndex: int): uint16 {.inline.} =
  ## Read rate_config from rate entry base + 10.
  rcU16(stats, rateEntryIndex * RC_RATE_ENTRY_SIZE + 10)

proc rcSetRateConfig(stats: pointer, rateEntryIndex: int, rateConfigWord: uint16) {.inline.} =
  ## Write rate_config to rate entry base + 10.
  rcU16(stats, rateEntryIndex * RC_RATE_ENTRY_SIZE + 10) = rateConfigWord

const RcRandomRateAttemptLimit = 64

proc rc_pick_non_duplicate_rate(stats: pointer): uint16 =
  ## Pick a non-duplicate sample rate with a deterministic fallback.
  ## rc_new_random_rate can keep returning existing entries, so production
  ## firmware must not rely on RNG convergence for scheduler progress.
  if stats == nil or rcU16(stats, RCS_N_RATES) > RC_MAX_RATE_ENTRIES.uint16:
    return 0xFFFF'u16
  let caps = rcRateCapabilities(stats)
  if caps.formatMod > 3:
    return 0xFFFF'u16
  var tries = 0
  while tries < RcRandomRateAttemptLimit:
    let randomRate = rc_new_random_rate(stats)
    if randomRate != 0xFFFF'u16 and rc_check_rate_duplicated(stats, randomRate) == 0:
      return randomRate
    inc tries

  if caps.formatMod > 1:
    if caps.maxNss.int >= caps.mcsBitmaps.len or caps.maxBandwidth > 3 or caps.shortGi > 1:
      return 0xFFFF'u16
    let minBandwidth = if caps.maxBandwidth == 0: 0 else: caps.maxBandwidth.int - 1
    for group in 0 .. caps.maxNss.int:
      let bitmap = caps.mcsBitmaps[group]
      for bandwidth in minBandwidth .. caps.maxBandwidth.int:
        for gi in countdown(caps.shortGi.int, 0):
          for mcs in 0 .. min(caps.maxMcs.int, 7):
            if ((bitmap shr mcs) and 1'u8) != 0:
              let candidate = (caps.formatMod.uint16 shl 11) or
                (group.uint16 shl 3) or mcs.uint16 or
                (bandwidth.uint16 shl 7) or (gi.uint16 shl 9)
              if rc_check_rate_duplicated(stats, candidate) == 0:
                return candidate
    if caps.lowestLegacyRate > 3:
      return 0xFFFF'u16

  let lo = caps.lowestLegacyRate
  let hi = caps.highestLegacyRate
  if lo > hi or hi >= 16 or caps.preambleType > 1:
    return 0xFFFF'u16
  let legacyFormat = if caps.formatMod <= 1: caps.formatMod.uint16 shl 11 else: 0'u16
  var fallbackRateIndex = lo
  while fallbackRateIndex <= hi:
    if ((caps.legacyRateMap shr fallbackRateIndex) and 1'u16) != 0:
      let baseRate = legacyFormat or fallbackRateIndex.uint16
      if fallbackRateIndex == 0:
        let candidate = baseRate or 0x400'u16
        if rc_check_rate_duplicated(stats, candidate) == 0:
          return candidate
      elif caps.formatMod > 1 or fallbackRateIndex <= 3:
        for preamble in caps.preambleType.int .. 1:
          let candidate = baseRate or (preamble.uint16 shl 10)
          if rc_check_rate_duplicated(stats, candidate) == 0:
            return candidate
      elif rc_check_rate_duplicated(stats, baseRate) == 0:
        return baseRate
    inc fallbackRateIndex
  0xFFFF'u16

proc rcRateTp(stats: pointer, rateEntryIndex: int): uint16 {.inline.} =
  ## Read throughput value from rate entry base + 8.
  rcU16(stats, rateEntryIndex * RC_RATE_ENTRY_SIZE + 8)

proc rcCountBitsInMap(rateMap: uint16, fromBit: int, toBit: int): uint16 =
  ## Count set bits in rateMap from fromBit to toBit (inclusive).
  var count: uint16 = 0
  for rateMapBitIndex in fromBit .. toBit:
    if (rateMap and (1'u16 shl rateMapBitIndex)) != 0:
      inc count
  return count

proc rcHighestBit(rateBitmapByte: uint8): uint8 =
  ## Find index of highest set bit in a byte (0-7). Returns 0 if rateBitmapByte==0.
  var highestSetBitIndex: uint8 = 0
  var remainingBits = rateBitmapByte
  while remainingBits > 1:
    remainingBits = remainingBits shr 1
    inc highestSetBitIndex
  return highestSetBitIndex
