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
    {.emit: ["asm volatile(\"csrrci %0, mstatus, 8\" : \"=r\"(", irqPrev, ") );"].}
    irqPrev

template irqRestore(prev: uint32) =
  if (prev and 8) != 0:
    {.emit: ["asm volatile(\"csrsi mstatus, 8\");"].}

proc macTimeNow(): uint32 {.inline.} =
  ## Read current MAC HW timestamp.
  regRead(MACHW_TIMLO_REG)

proc platformDelay(us: uint32) {.inline.} =
  ## Simple busy-wait delay (approximate microseconds).
  ## From blob: wifi_main calls delay(100) during INTC clock toggle.
  var delayLoopBudget = us * 10'u32  # approximate loop count for ~1us per 10 iterations
  while delayLoopBudget > 0:
    {.emit: ["asm volatile(\"nop\");"].}
    dec delayLoopBudget

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
  ## Get pointer to a rate entry within rc_sta_stats.
  ## Rate entries start at offset 0, each 12 bytes.
  cast[pointer](cast[uint](stats) + (rateEntryIndex * RC_RATE_ENTRY_SIZE).uint)

template rcRateEntryAt(p: pointer): ptr RcRateEntryView =
  cast[ptr RcRateEntryView](p)

template rcRateEntry(stats: pointer, rateEntryIndex: uint16): ptr RcRateEntryView =
  cast[ptr RcRateEntryView](cast[uint](stats) + rateEntryIndex.uint * RC_RATE_ENTRY_SIZE.uint)

template rcRateResetFields(stats: pointer, rateEntryIndex: uint16): ptr RcRateResetFieldsView =
  cast[ptr RcRateResetFieldsView](cast[uint](stats) + rateEntryIndex.uint * RC_RATE_ENTRY_SIZE.uint)

template rcThroughputArray(tpArray: pointer): ptr UncheckedArray[uint32] =
  cast[ptr UncheckedArray[uint32]](tpArray)

template rcStatsCounters(stats: pointer): ptr RcStatsCounterView =
  cast[ptr RcStatsCounterView](stats)

proc rcClearRateEntryTransientStats(stats: pointer; rateEntryIndex: uint16) {.inline.} =
  let resetFields = rcRateResetFields(stats, rateEntryIndex)
  resetFields.sampleSkipped = 0
  resetFields.initialized = 1
  resetFields.attempts0 = 0
  resetFields.oldProb = 0

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
  var randomRate: uint16 = 0xFFFF'u16
  var tries = 0
  while tries < RcRandomRateAttemptLimit:
    randomRate = rc_new_random_rate(stats)
    if rc_check_rate_duplicated(stats, randomRate) == 0:
      return randomRate
    inc tries

  let fmtForFill = rcU8(stats, RCS_FORMAT_MOD)
  if fmtForFill <= 1:
    let rateMap = rcU16(stats, RCS_RATE_MAP)
    let lo = rcU8(stats, RCS_LOWEST_IDX)
    let hi = rcU8(stats, RCS_HIGHEST_IDX)
    let bw = rcU8(stats, RCS_BW_MAX).uint16 shl 10
    var fallbackRateIndex = lo
    while fallbackRateIndex <= hi:
      if ((rateMap shr fallbackRateIndex) and 1'u16) != 0:
        var candidate = (fmtForFill.uint16 shl 11) or fallbackRateIndex.uint16
        if fallbackRateIndex == 0:
          candidate = candidate or 0x400'u16
        elif fallbackRateIndex - 1 <= 2:
          candidate = candidate or bw
        if rc_check_rate_duplicated(stats, candidate) == 0:
          return candidate
      if fallbackRateIndex == 0xFF'u8:
        break
      inc fallbackRateIndex
  else:
    let groupCnt = rcU8(stats, RCS_GROUP_CNT)
    let maxMcs = rcU8(stats, RCS_MAX_NSS_MCS)
    let sgi = rcU8(stats, RCS_SHORT_GI)
    var group: uint8 = 0
    while group <= groupCnt:
      let bitmap = rcU8(stats, RCS_RATE_BITMAP + group.int)
      var mcs: uint8 = 0
      while mcs <= maxMcs and mcs < 8:
        if ((bitmap shr mcs) and 1'u8) != 0:
          var candidate = (fmtForFill.uint16 shl 11) or
                          (group.uint16 shl 3) or mcs.uint16
          if sgi != 0:
            candidate = candidate or 0x200'u16
          if rc_check_rate_duplicated(stats, candidate) == 0:
            return candidate
        inc mcs
      if group == 0xFF'u8:
        break
      inc group
  0xFFFF'u16

proc rcRateEntryTp(stats: pointer, rateEntryIndex: int): uint16 {.inline.} =
  ## Read throughput estimate from rate entry base + 8.
  rcU16(stats, rateEntryIndex * RC_RATE_ENTRY_SIZE + 8)

proc rcRateEntryProb(stats: pointer, rateEntryIndex: int): uint16 {.inline.} =
  ## Read probability EWMA from rate entry base + 4.
  rcU16(stats, rateEntryIndex * RC_RATE_ENTRY_SIZE + 4)

proc rcRateTp(stats: pointer, rateEntryIndex: int): uint16 {.inline.} =
  ## Read throughput value from rate entry base + 8.
  rcU16(stats, rateEntryIndex * RC_RATE_ENTRY_SIZE + 8)

proc rcRateEntryRetry(stats: pointer, rateEntryIndex: int): uint8 {.inline.} =
  ## Read retry count from rate entry base + 12.
  rcU8(stats, rateEntryIndex * RC_RATE_ENTRY_SIZE + 12)

proc rcRateEntryFlags(stats: pointer, rateEntryIndex: int): uint8 {.inline.} =
  ## Read flags byte from rate entry base + 13.
  rcU8(stats, rateEntryIndex * RC_RATE_ENTRY_SIZE + 13)

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
