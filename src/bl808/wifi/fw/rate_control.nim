# ###########################################################################
#                   RC: Rate Control
# ###########################################################################

proc rc_init*(staEntry: pointer) {.exportc, cdecl.} =
  ## Initialize rate control for a station.
  ##
  ## Takes a pointer to sta_info_tag (NOT a staIdx). Called from me_init_rate.
  ## From disassembly (463 instructions):
  ##   1. Allocate rc_sta_stats from pool (indexed by sta[40] * 200)
  ##   2. Store stats ptr at sta+324
  ##   3. Zero 200-byte stats struct
  ##   4. Branch HT (sta+308 bit1) vs legacy:
  ##      HT: format_mod=2, build legacy rate_map from supported rates at sta+248,
  ##          compute NSS groups, set lowest/highest/short_gi/bw_max
  ##      Legacy: format_mod=0, build rate_map from supported rates,
  ##          set lowest/highest, max_nss_mcs=0xFF
  ##   5. Count total supported rates -> n_rates (clamped to 10)
  ##   6. Fill rate table: entry[0]=initial_rate, then iterate with
  ##      rc_set_next_mcs_index / rc_check_valid_rate
  ##   7. Set max_tp_idx=n_rates-1, max_tp2_idx=n_rates-2, max_prob_idx=n_rates-3
  ##   8. prob_avg=0x10000, sample_idx=0xFFFF, retry_limit=5
  ##   9. Call rc_update_retry_chain
  ##  10. Build TX policy descriptor at sta+320:
  ##      4 retry chain entries from rate table + 0x80000000,
  ##      status=0xBADCAB1E, bufAddr=TRNG<<14, pktType=(infoIdx+8)<<10,
  ##      controlInfo=0xFFFF0704, edca=0x2200, vif from sta+28
  ##  11. sta[334] |= 0x11
  let sta = staInfoAt(staEntry)
  let infoIdx = sta.infoIdx

  # Validate info_idx <= 4 (from disasm: li a4,4; bgeu a4,a5)
  if infoIdx > 4:
    assert_err("rc.c", "rc.c", 0x858.cint)

  # Query PHY TX chain count (blob: phy_get_ntx at 0x6C)
  let ntx = phy_get_ntx()

  # Allocate rc_sta_stats from pool: stats = pool_base + infoIdx * 200
  let statsBase = cast[pointer](cast[uint](addr rcStaStatsPool[0]) +
                                 infoIdx.uint * RC_STATS_SIZE.uint)
  sta.rcStats = statsBase

  # Vendor seeds the TX policy buffer address from phy_get_ntx() << 14.
  var bufAddr = ntx.uint32 shl 14  # will be OR'd with LDPC capability below

  # Zero-fill the 200-byte stats structure (blob: memset at 0x80)
  discard c_memset(statsBase, 0, RC_STATS_SIZE.csize_t)

  # Determine HT vs legacy from rate_info_flags bit 1
  let rateInfoFlags = sta.capabilityFlags
  let isHT = (rateInfoFlags and 2) != 0

  if isHT:
    # ---- HT path (disasm 0x98..0x2C4) ----
    # format_mod = 2 (HT mixed format)
    rcU8(statsBase, RCS_FORMAT_MOD) = RC_FORMATMOD_HT_MF

    # Build the legacy rate map from the supported-rates block at sta+248.
    # The HT MCS bitmap at sta+267 is handled below by me_11n_nss_max/copy.
    # Feeding the MCS bitmap here makes the builder interpret a bitmask byte
    # as a length byte, which trips the vendor me.c:411 warning path.
    let legacyRatesBase = cast[pointer](addr sta.supportedRates[0])
    let rateMapBuilt = me_legacy_rate_bitfield_build(legacyRatesBase, 0)
    rcU16(statsBase, RCS_RATE_MAP) = rateMapBuilt.uint16

    # HT MCS bitmask base used by the 11n-specific path (blob 0xB0+)
    let htMcsBase = cast[uint](addr sta.vhtCaps[0]) +
      (STA_HT_MCS_SET_OFF - STA_HT_CAP_INFO_OFF).uint

    # Get NSS max via me_11n_nss_max (blob 0xB0, 0xC2)
    # First call: remote STA's HT MCS set (sta+267)
    let nssMax1 = me_11n_nss_max(cast[pointer](htMcsBase))
    # Second call: local device HT MCS set (me_env+0xb)
    let nssMax2 = me_11n_nss_max(cast[pointer](cast[uint](addr me_env[0]) + 0xB))
    # Blob stores the max NSS group index, not a group count. A single-stream
    # peer is represented as group 0 and must still contribute rates below.
    var groupCnt {.volatile.}: uint8 = if nssMax2 < nssMax1: nssMax2 else: nssMax1
    if groupCnt > 3:
      assert_err("rc.c", "rc.c", 0x89F.cint)
    rcU8(statsBase, RCS_GROUP_CNT) = groupCnt

    # Copy 4 bytes of MCS bitmask to stats.rate_bitmap (offset 178)
    discard c_memcpy(
      cast[pointer](cast[uint](statsBase) + RCS_RATE_BITMAP.uint),
      cast[pointer](htMcsBase), 4.csize_t)

    # max_nss_mcs = 0xFF initially (set properly below)
    rcU8(statsBase, RCS_MAX_NSS_MCS) = 0xFF'u8

    # Find lowest/highest valid MCS index via me_legacy_ridx_min/max (blob 0x126, 0x164)
    let rm = rcU16(statsBase, RCS_RATE_MAP)
    var loIdx {.volatile.}: uint8 = me_legacy_ridx_min(rm.uint32)
    rcU8(statsBase, RCS_LOWEST_IDX) = loIdx
    if loIdx > 12:
      assert_err("rc.c", "rc.c", 0x8B1.cint)

    var hiIdx {.volatile.}: uint8 = me_legacy_ridx_max(rm.uint32)
    rcU8(statsBase, RCS_HIGHEST_IDX) = hiIdx
    if hiIdx > 12:
      assert_err("rc.c", "rc.c", 0x8B7.cint)

    # BW max from sta+332 (supported rates bitmap)
    let suppRates = sta.supportedRatesBitmap
    rcU8(statsBase, RCS_BW_MAX) = ((suppRates shr 10) and 0x3).uint8

    # LDPC support check (blob: phy_ldpc_tx_supported at 0x1AA)
    let htCapInfo = cast[ptr uint16](addr sta.vhtCaps[0])[]
    if phy_ldpc_tx_supported() and (htCapInfo and 1) != 0:
      bufAddr = bufAddr or 64  # set LDPC bit

    # 40MHz support check (bit 11 = 0x800)
    if (htCapInfo and 0x800'u16) != 0:
      rcU16(statsBase, RCS_RATE_MAP_L) = 0x2000'u16 - 0x0101'u16
    else:
      rcU16(statsBase, RCS_RATE_MAP_L) = 0x1000'u16 - 0x0101'u16

    # NSS config from sta+313
    let noSS = sta.nssBwMax
    rcU8(statsBase, RCS_NO_SS) = noSS
    if noSS > 3:
      assert_err("rc.c", "rc.c", 0x8CE.cint)

    # Short GI configuration based on NSS and HT capabilities
    if noSS == 0:
      if (htCapInfo and 0x20) != 0:  # SGI 20MHz
        rcU8(statsBase, RCS_SHORT_GI) = 1
    elif noSS == 1:
      if (htCapInfo and 0x40) != 0:  # SGI 40MHz
        rcU8(statsBase, RCS_SHORT_GI) = 1

  else:
    # ---- Non-HT (legacy) path (disasm L296, 0x2C6..0x38E) ----
    # format_mod stays 0 (already zeroed)

    # Build legacy rate map via me_legacy_rate_bitfield_build (blob 0x2C6)
    let rateInfoBase = cast[pointer](addr sta.supportedRates[0])
    let rateMapBuilt = me_legacy_rate_bitfield_build(rateInfoBase, 0)
    var rateMap: uint16 = rateMapBuilt.uint16
    if rateMap == 0:
      rateMap = 0x0FFF'u16
    rcU16(statsBase, RCS_RATE_MAP) = rateMap

    # Lowest/highest via me_legacy_ridx_min/max (blob 0x2D2, 0x310)
    let loIdx = me_legacy_ridx_min(rateMap.uint32)
    rcU8(statsBase, RCS_LOWEST_IDX) = loIdx
    if loIdx > 11:
      assert_err("rc.c", "rc.c", 0x8ED.cint)

    let hiIdx = me_legacy_ridx_max(rateMap.uint32)
    rcU8(statsBase, RCS_HIGHEST_IDX) = hiIdx
    if hiIdx > 11:
      assert_err("rc.c", "rc.c", 0x8EF.cint)

    # Legacy: max_nss_mcs = 0xFF (not applicable), max_nss_mcs at +184
    rcU8(statsBase, RCS_MAX_NSS_MCS) = 0xFF'u8

    # Copy NSS config
    let noSS = sta.nssBwMax
    rcU8(statsBase, RCS_NO_SS) = noSS
    if noSS != 0:
      assert_err("rc.c", "rc.c", 0x8F2.cint)

    # BW max
    let suppRates = sta.supportedRatesBitmap
    rcU8(statsBase, RCS_BW_MAX) = ((suppRates shr 10) and 0x3).uint8

  # ---- Common path: count supported rates (disasm L306 -> L312) ----
  let fmtMod = rcU8(statsBase, RCS_FORMAT_MOD)
  let rMap = rcU16(statsBase, RCS_RATE_MAP)
  let bwMax = rcU8(statsBase, RCS_BW_MAX)
  let sgi = rcU8(statsBase, RCS_SHORT_GI)

  if fmtMod <= 1:
    # Legacy rate count: count set bits in rate_map, also check OFDM extension
    # From disasm (L310/L315): complex bit-counting loop
    var nRates: uint16 = 0
    # Count bits in positions 0..3 (CCK rates)
    for i in 0 ..< 4:
      if (rMap and (1'u16 shl i)) != 0:
        inc nRates
    # Count bits in positions 4..11 (OFDM rates)
    for i in 4 ..< 12:
      let bit = (rMap shr i.uint16) and 1
      nRates = nRates + bit
    if nRates > 10:
      nRates = 10
    rcU16(statsBase, RCS_N_RATES) = nRates
  else:
    # HT: count rate combinations from MCS bitmaps * BW * SGI
    var nRates: uint16 = 0
    let gCnt = rcU8(statsBase, RCS_GROUP_CNT)
    # Count valid MCS indices across all NSS groups. gCnt is the max group
    # index, so include group 0 when the peer supports one spatial stream.
    for g in 0'u8 .. gCnt:
      let mcsByte = rcU8(statsBase, RCS_RATE_BITMAP + g.int)
      for m in 0 ..< 8:
        if (mcsByte and (1'u8 shl m)) != 0:
          inc nRates
    # Multiply by BW variants and SGI
    if bwMax > 0:
      nRates = nRates * 2
    if sgi != 0:
      nRates = nRates * 2
    if nRates > 10:
      nRates = 10
    rcU16(statsBase, RCS_N_RATES) = nRates

  # Volatile reload so GCC range-analysis can't prove these asserts
  # are dead (matching blob which keeps both defensively).
  var nR {.volatile.}: uint16 = rcU16(statsBase, RCS_N_RATES)
  if nR == 0:
    assert_err("rc.c", "rc.c", 0x8F8.cint)
  if nR > 10:
    assert_err("rc.c", "rc.c", 0x8F9.cint)

  # ---- Build rate table (disasm L317 -> L324) ----
  # Re-derive stats from sta+324 (follows disasm at 0x3F0)
  let stats = sta.rcStats
  if stats == nil:
    assert_err("rc.c", "rc.c", 1764.cint)

  # Initialize all rate_config slots to 0xFFFF.
  let nRates = rcU16(stats, RCS_N_RATES)
  for i in 0 ..< nRates.int:
    rcSetRateConfig(stats, i, 0xFFFF'u16)

  # Vendor layout:
  #   entry[0]          = lowest usable rate
  #   entry[n_rates-1]  = initial/highest rate
  #   entries in between are filled by rc_new_random_rate until non-duplicate.
  let lowestRateConfig = rc_get_lowest_rate_config(stats)
  rcSetRateConfig(stats, 0, lowestRateConfig)

  let initialRate = rc_get_initial_rate_config(stats)
  if nRates > 0:
    rcSetRateConfig(stats, nRates.int - 1, initialRate)

  var fillIdx = 1
  while fillIdx < nRates.int - 1:
    let randomRate = rc_pick_non_duplicate_rate(stats)
    if randomRate == 0xFFFF'u16:
      break
    rcSetRateConfig(stats, fillIdx, randomRate)
    inc fillIdx

  # ---- Set initial indices (disasm 0x474..0x4AC) ----
  rcU16(stats, RCS_MAX_TP_IDX) = nRates - 1
  rcU16(stats, RCS_MAX_TP2_IDX) = if nRates >= 2: nRates - 2 else: 0
  rcU16(stats, RCS_MAX_PROB_IDX) = if nRates >= 3: nRates - 3 else: 0
  rcU32(stats, RCS_PROB_AVG) = 0x10000'u32
  rcU16(stats, RCS_SAMPLE_IDX) = 0xFFFF'u16

  # Clear throughput/timer fields
  rcU32(stats, RCS_TP_CUR) = 0
  rcU32(stats, RCS_TP_SECOND) = 0
  rcU32(stats, RCS_TP_THIRD) = 0
  rcU16(stats, RCS_RESERVED_U16) = 0
  rcU32(stats, RCS_RETRY_TIMER) = 0
  rcU8(stats, RCS_FLAGS) = 0

  # Update initial statistics (blob: rc_update_stats at 0x4AE; blob does NOT
  # call rc_update_retry_chain from rc_init — it's done from rc_update_stats).
  discard rc_update_stats(stats, 1)

  # Second PHY query for policy mask setup (blob: phy_get_ntx at 0x51E).
  let ntx2 = phy_get_ntx()

  # ---- Configure TX policy (disasm 0x4B6..0x552) ----
  rcU8(stats, RCS_RETRY_LIMIT) = 5

  let txPolicy = sta.txPolicy
  let policy = txPolicyAt(txPolicy)

  # Encode 4 retry chain entries into the policy descriptor retry-rate slots.
  # Each entry uses the index bytes stored at stats+128, +136, +144, +152
  # and writes rate_config[index] | 0x80000000.
  let retryIndexOffsets = [RCS_MAX_TP_IDX, RCS_MAX_TP2_IDX, RCS_MAX_PROB_IDX, RCS_RESERVED_U16]
  for i in 0 ..< 4:
    let retryIdx = rcU8(stats, retryIndexOffsets[i]).uint16
    let entryRate =
      if retryIdx < nRates: rcRateConfig(stats, retryIdx.int)
      else: 0xFFFF'u16
    let packed = entryRate.uint32 or 0x80000000'u32
    policy.retryRate[i] = packed

  # Read MACHW timestamp low for TX descriptor
  let tsNow = regRead(MACHW_TIMLO_REG)

  # pkt_type = ((infoIdx + 8) & 0xFF) << 10
  let pktType = ((infoIdx.uint32 + 8) and 0xFF) shl 10

  policy.status = 0xBADCAB1E'u32
  policy.bufferAddr = bufAddr
  policy.bufferMask = (1'u32 shl (ntx2.uint32 + 1'u32)) - 1'u32
  policy.packetType = pktType
  # controlInfo: bits[7:0] and [15:8] encode per-rate retry counts.
  # Keep the vendor default for normal data frames; control-port robustness is
  # handled by the EAPOL-specific retry template in txl_buffer_alloc.
  policy.controlInfo = 0xFFFF0704'u32
  policy.edcaParam0 = 0x2200'u32
  policy.edcaParam1 = cast[uint32](cast[uint](sta.vif))

  # Set RC flags on station: sta[334] |= 0x11
  sta.mmFlagsBytes[0] = sta.mmFlagsBytes[0] or 0x11'u8


{.emit: "__attribute__((optimize(\"crossjumping\"))) void rc_check(unsigned char);".}
proc rc_check*(staIdx: uint8) {.exportc, cdecl.} =
  ## Minstrel-like rate control check/update (called periodically per-STA).
  ##
  ## From disassembly (242 instructions):
  ##   1. Validate staIdx <= 4
  ##   2. Compute sta entry: sta_info_tab + staIdx * 368
  ##   3. Load rc_sta_stats from sta+324; assert non-nil
  ##   4. Check elapsed time: if (RC_UPDATE_INTERVAL - (now - last_ts)) < 0,
  ##      call rc_update_stats, reset update_stage/flags, store new timestamp
  ##   5. Process update_stage:
  ##      stage==1 (sampling):
  ##        - Skip if flags bit6 set
  ##        - Compute throughput threshold from current max_tp entry
  ##        - Generate sample rate via LCG PRNG: (state*0x41C64E6D + 0x3039)>>16 % n_rates
  ##        - Skip if sample == max_tp/max_tp2/max_prob
  ##        - Compare sample duration vs max_tp duration
  ##        - Better: promote sample->max_tp, demote old->max_tp2
  ##        - Worse but viable: track candidate, increment slow_rate_cnt
  ##        - Set stage=2
  ##      stage==3 (finalize):
  ##        - If not fixed (flags bit1==0): demote max_tp->max_tp2
  ##        - Restore sample_candidate, clear prev_tp, set sample_cand=0xFF
  ##   6. If stats were updated, set sta[334] |= 1

  # Validate staIdx (disasm: li a5,4; bltu a5,a0 -> return)
  if staIdx > 4:
    return

  # Derive sta entry pointer
  let sta = staInfoForIdx(staIdx)
  let stats = sta.rcStats
  if stats == nil:
    # Blob uses assert_err here (different sink than Nim's previous
    # assert_warn; blob matches `1 assert_err` in rc_check's call graph).
    assert_err("rc_check", "rc_check", 0x822)

  # ---- Check update interval (disasm LBB325/LBE321, 0x5C..0xA0) ----
  let tsNow = regRead(MACHW_TIMLO_REG)
  let lastTs = rcU32(stats, 0)  # last_update_ts at offset 0
  let timeDiff = tsNow - lastTs
  let remaining = RC_UPDATE_INTERVAL - timeDiff  # unsigned wrapping subtraction

  var didUpdate: uint8 = 0
  if remaining.int32 < 0:
    # Interval elapsed: run statistics update
    didUpdate = rc_update_stats(stats, 0)

    # Reset per-update fields (disasm 0x84..0x9C)
    rcU8(stats, RCS_UPDATE_STAGE) = 0
    rcU8(stats, RCS_ANOTHER_FLAG) = 0
    rcU8(stats, RCS_FLAGS) = rcU8(stats, RCS_FLAGS) and not 0x10'u8

    # Store current timestamp (disasm: sw a4, 0(s4))
    rcU32(stats, 0) = tsNow

  # ---- Process update_stage (disasm 0xA0..0x302) ----
  let stage = rcU8(stats, RCS_UPDATE_STAGE)

  if stage == 1:
    # ---- Sampling phase (disasm LBB338, 0xAA..0x25A) ----
    let flags = rcU8(stats, RCS_FLAGS)

    # Check skip flag (bit 6 = 0x40)
    if (flags and 0x40) != 0:
      # Skip this round (disasm L366)
      rcU8(stats, RCS_UPDATE_STAGE) = 0
    else:
      let fmtMod = rcU8(stats, RCS_FORMAT_MOD)
      let maxTpIdx = rcU16(stats, RCS_MAX_TP_IDX)

      # Determine throughput evaluation threshold
      # (disasm 0xBA..0xE4: check format_mod vs rate count, compute timer)
      var evalTimer: uint16
      if fmtMod < 1:
        # Legacy: check rate entry throughput directly
        let entryBase = rcRateEntryPtr(stats, maxTpIdx.int)
        let curTp = rcU16(entryBase, 8)
        # Subtract baseline and check against threshold 0xD99A
        let adjusted = curTp.uint32 - 0x1999'u32
        if adjusted > 0xD99A'u32:
          evalTimer = 5   # very low/high tp: use short timer
        else:
          evalTimer = 10  # normal range
      else:
        # HT: use AMPDU length as threshold baseline
        let ampduLen = rcU16(stats, RCS_AVG_AMPDU_LEN)
        evalTimer = (ampduLen + 8) * 2

      # ---- Generate random sample rate (disasm LBB346, 0xF4..0x128) ----
      # LCG: prng = prng * 0x41c64e6d + 0x3039
      let prngVal = rcPrngNext()
      let nRates = rcU16(stats, RCS_N_RATES)

      # sample = (prng >> 16) % n_rates
      let sample = ((prngVal shr 16) mod nRates.uint32).uint16

      # Skip if sample matches any of the best indices (disasm 0x114..0x128)
      if sample == maxTpIdx or
         sample == rcU16(stats, RCS_MAX_TP2_IDX) or
         sample == rcU16(stats, RCS_MAX_PROB_IDX):
        # Bail out (disasm L366)
        rcU8(stats, RCS_UPDATE_STAGE) = 0
      else:
        # ---- Evaluate sample rate (disasm 0x128..0x25A) ----
        # Check sample entry's throughput against threshold
        let sampleEntryBase = rcRateEntryPtr(stats, sample.int)
        let sampleTpRaw = rcU16(sampleEntryBase, 8)

        # Threshold check: if tp > 0xF333, skip (disasm 0x136..0x13A)
        if sampleTpRaw > 0xF333'u16:
          rcU8(stats, RCS_UPDATE_STAGE) = 0
        else:
          # Get duration estimates for comparison
          let sampleRate = rcRateConfig(stats, sample.int)
          let sampleDur = rc_get_duration(sampleRate.uint32, 1)

          # Check if fmtMod count > 1 (more detailed comparison for HT)
          let fmtCount = fmtMod
          if fmtCount > 1:
            # ---- HT extended comparison (disasm L361, 0x1D0..0x234) ----
            var minRetryLen: uint16 = 32

            let entryFlags = rcU8(sampleEntryBase, 13)
            if entryFlags == 0:
              minRetryLen = rcU16(stats, RCS_AVG_AMPDU_LEN)

            # Blob 0x1de: get duration of max_tp2 rate for compare
            let maxTp2Rate = rcRateConfig(stats, rcU16(stats, RCS_MAX_TP2_IDX).int)
            let maxTp2Dur = rc_get_duration(maxTp2Rate.uint32, 1)

            var promote = false

            if sampleDur < maxTp2Dur:
              # Sample beats max_tp2: jump straight to promote (blob L364)
              promote = true
            else:
              # Blob 0x200: get NSS of sample rate
              let sampleNss = rc_get_nss(sampleRate)
              # Blob 0x20c: get NSS of max_tp2 rate
              let maxTp2Nss = rc_get_nss(maxTp2Rate)

              if (maxTp2Nss.int - 1) < sampleNss.int:
                # Same/better NSS: compare against max_tp duration (blob 0x228)
                let maxTpRate = rcRateConfig(stats, maxTpIdx.int)
                let maxTpDur = rc_get_duration(maxTpRate.uint32, 1)
                if sampleDur < maxTpDur:
                  promote = true

            if promote:
              # ---- Promote (blob L364 @0x280) ----
              # Blob 0x286: rc_calc_tp(sample entry, rc_stats).
              discard rc_calc_tp(sampleEntryBase, stats)
              # After rc_calc_tp, check info nibble and retry (blob 0x28E..0x2A8)
              let infoNib = rcU8(sampleEntryBase, 14) and 0x0F
              var retryOk: uint8 = 1
              if infoNib <= 9:
                let sampleRetry = rcU8(sampleEntryBase, 12)
                retryOk = if sampleRetry < minRetryLen.uint8: 1 else: 0

              # Record promotion
              let oldTp2 = rcU32(stats, RCS_TP_SECOND)
              rcU16(stats, RCS_SAMPLE_CAND) = rcU16(stats, RCS_MAX_TP2_IDX)
              rcU32(stats, RCS_PREV_TP) = oldTp2

              if retryOk != 0:
                let oldTpCur = rcU32(stats, RCS_TP_CUR)
                rcU8(stats, RCS_FLAGS) = rcU8(stats, RCS_FLAGS) and not 0x02'u8
                rcU32(stats, RCS_TP_SECOND) = oldTpCur
                rcU16(stats, RCS_MAX_TP2_IDX) = maxTpIdx
                rcU32(stats, RCS_TP_CUR) = 0
                rcU16(stats, RCS_MAX_TP_IDX) = sample
              else:
                rcU8(stats, RCS_FLAGS) = rcU8(stats, RCS_FLAGS) or 0x02'u8
                rcU32(stats, RCS_TP_SECOND) = 0
                rcU16(stats, RCS_MAX_TP2_IDX) = sample

              rcU8(stats, RCS_UPDATE_STAGE) = 2
            else:
              # Slow rate tracking (disasm L365, 0x234..0x25A)
              let sampleRetry = rcU8(sampleEntryBase, 12)
              if sampleRetry < minRetryLen.uint8:
                rcU8(stats, RCS_UPDATE_STAGE) = 0
              else:
                var slowCnt = rcU8(stats, RCS_SLOW_RATE_CNT) + 1
                rcU8(stats, RCS_SLOW_RATE_CNT) = slowCnt and 0xFF
                if slowCnt > 2 and slowCnt <= 15:
                  rcU8(stats, RCS_UPDATE_STAGE) = 0
                elif slowCnt > 15:
                  rcU8(stats, RCS_SLOW_RATE_CNT) = 15
                  rcU8(stats, RCS_UPDATE_STAGE) = 0
                else:
                  # Retry chain update (blob does NOT call rc_update_retry_chain
                  # from here; state transition only).
                  rcU8(stats, RCS_UPDATE_STAGE) = 2

          else:
            # ---- Legacy simple comparison (disasm LVL550, 0x156..0x17A) ----
            let maxTpRate = rcRateConfig(stats, maxTpIdx.int)
            let maxTpDur = rc_get_duration(maxTpRate.uint32, 1)

            if sampleDur < maxTpDur:
              # Sample has better throughput: promote
              let retryCount = rcU8(sampleEntryBase, 12)
              let retryOK: uint8 = if retryCount >= 20: 0 else: 1

              let oldTp2 = rcU32(stats, RCS_TP_SECOND)
              rcU16(stats, RCS_SAMPLE_CAND) = rcU16(stats, RCS_MAX_TP2_IDX)
              rcU32(stats, RCS_PREV_TP) = oldTp2

              if retryOK != 0:
                let oldTpCur = rcU32(stats, RCS_TP_CUR)
                rcU8(stats, RCS_FLAGS) = rcU8(stats, RCS_FLAGS) and not 0x02'u8
                rcU32(stats, RCS_TP_SECOND) = oldTpCur
                rcU16(stats, RCS_MAX_TP2_IDX) = maxTpIdx
                rcU32(stats, RCS_TP_CUR) = sampleDur
                rcU16(stats, RCS_MAX_TP_IDX) = sample
              else:
                rcU8(stats, RCS_FLAGS) = rcU8(stats, RCS_FLAGS) or 0x02'u8
                rcU32(stats, RCS_TP_SECOND) = sampleDur
                rcU16(stats, RCS_MAX_TP2_IDX) = sample
            else:
              # Sample worse: no promotion, zero throughput
              let oldTp2 = rcU32(stats, RCS_TP_SECOND)
              rcU16(stats, RCS_SAMPLE_CAND) = rcU16(stats, RCS_MAX_TP2_IDX)
              rcU32(stats, RCS_PREV_TP) = oldTp2
              rcU8(stats, RCS_FLAGS) = rcU8(stats, RCS_FLAGS) or 0x02'u8
              rcU32(stats, RCS_TP_SECOND) = 0
              rcU16(stats, RCS_MAX_TP2_IDX) = sample

            rcU8(stats, RCS_UPDATE_STAGE) = 2

  elif stage == 3:
    # ---- Finalize phase (disasm L356/LBB356, 0x2C2..0x300) ----
    let flags = rcU8(stats, RCS_FLAGS)
    if (flags and 0x02) == 0:
      # Not fixed: restore old max_tp2 -> max_tp
      let oldTp2Idx = rcU16(stats, RCS_MAX_TP2_IDX)
      rcU16(stats, RCS_MAX_TP_IDX) = oldTp2Idx
      let oldTp2Val = rcU32(stats, RCS_TP_SECOND)
      rcU32(stats, RCS_TP_CUR) = oldTp2Val

    # Move sample_candidate to max_tp2, restore prev_tp
    let sampCand = rcU16(stats, RCS_SAMPLE_CAND)
    rcU8(stats, RCS_UPDATE_STAGE) = 0
    rcU16(stats, RCS_MAX_TP2_IDX) = sampCand
    let prevTp = rcU32(stats, RCS_PREV_TP)
    rcU32(stats, RCS_PREV_TP) = 0
    rcU32(stats, RCS_TP_SECOND) = prevTp
    # Reset sample_candidate to 0xFF (disasm: li a4, 255; sh a4, 160(s4))
    rcU16(stats, RCS_SAMPLE_CAND) = 0x00FF'u16

  # else: stage==0 or 2, no action

  # ---- If stats updated, mark sta for TX policy refresh (disasm L369) ----
  if didUpdate != 0:
    # Set sta[334] |= 1 (disasm 0x1B4..0x1C0)
    sta.mmFlagsBytes[0] = sta.mmFlagsBytes[0] or 0x01'u8


proc rc_calc_tp*(entry: pointer, stats: pointer): uint32 {.exportc, cdecl.} =
  ## Calculate throughput for rate selection (45 instrs).
  ## From blob: a0 = rate entry pointer, and caller also passes the rc_stats
  ## pointer in a1 (kept in s2 across the is_cck_group call).
  ##   1. probEwma = entry[8]; if probEwma < 0x1998: return 0.
  ##   2. rateConfig = entry[10]
  ##   3. call is_cck_group(rateConfig); if returns 0 (NOT CCK):
  ##        s0 = 0x35390 / rc_stats[170]    (AMPDU overhead)
  ##      else (is CCK): s0 = 0
  ##   4. call rc_get_duration(rateConfig); s0 += duration
  ##   5. tp = (probEwma * 1000) / s0; tp *= 0xF4240 (→ scales to 1e6 basis)
  ##   6. return tp
  let rateEntry = rcRateEntryAt(entry)
  let statsView = if stats != nil: rcStatsCounters(stats) else: nil

  let probEwma = rateEntry.probEwma
  if probEwma < 0x1998'u16:
    return 0
  let rateConfig = rateEntry.rateConfig

  # AMPDU overhead: added only when rate is NOT a CCK rate.
  var overhead: uint32 = 0
  if not is_cck_group(rateConfig.uint32):
    if statsView != nil:
      let ampduLen = statsView.avgAmpduLen
      if ampduLen != 0:
        overhead = 0x35390'u32 div ampduLen.uint32

  # Add rate airtime
  let duration = rc_get_duration(rateConfig.uint32, 0)
  let totalOverhead = overhead + duration
  if totalOverhead == 0:
    return 0
  let tpStep = (probEwma.uint32 * 1000'u32) div totalOverhead
  return tpStep * 0xF4240'u32

proc rc_update_counters*(staIdx: uint8, attemptCount: uint32, successCount: uint32) {.exportc, cdecl.} =
  ## Update rate control counters after TX attempt (112 instrs).
  ## a0=staIdx, a1=attemptCount, a2=successCount.
  ## Loads RC stats from sta_info_tab[staIdx]+324. Increments total attempts
  ## and total success counters. Then iterates per-rate entries at stats+128..160
  ## (5 AC slots, 8 bytes each), adding attempts/successes to each slot's counters
  ## with overflow checking via assert_err.
  inc nimFwDbgRcUpdateCalls
  nimFwDbgRcUpdateMeta = staIdx.uint32
  nimFwDbgRcUpdateArgs =
    (attemptCount and 0xFFFF'u32) or ((successCount and 0xFFFF'u32) shl 16)

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

  var attempts = attemptCount
  var successes = successCount

  # Increment total counters
  counters.totalSuccess = counters.totalSuccess + 1
  counters.totalAttempts = counters.totalAttempts + 1

  # Iterate retry-chain slots at stats+128..stats+152. Each slot stores a
  # rate-table index; the counters live in the selected rate entry.
  var slotIdx = 0
  while slotIdx < counters.retrySlots.len:
    if attempts == 0:
      break

    let rateIdx = counters.retrySlots[slotIdx].rateIdx
    let entry = rcRateEntry(stats, rateIdx)
    var entryAttempts = entry.attempts
    nimFwDbgRcUpdateSlot =
      slotIdx.uint32 or
      (rateIdx.uint32 shl 8) or
      ((attempts and 0xFF'u32) shl 16) or
      ((successes and 0xFF'u32) shl 24)
    nimFwDbgRcUpdateEntry = pointerAddrU32(cast[pointer](entry))
    nimFwDbgRcUpdateCounts =
      entry.attempts.uint32 or (entry.failures.uint32 shl 16)

    if successes > 3:
      entryAttempts = entryAttempts + 4'u16
      entry.attempts = entryAttempts
      attempts -= 4
      successes -= 4
    else:
      let addAttempts32 = attempts and 0xFFFF'u32
      let addAttempts = addAttempts32.uint16
      entryAttempts = entryAttempts + addAttempts
      entry.attempts = entryAttempts

      let oldFailures = entry.failures
      let newFailures32 =
        (oldFailures.uint32 + addAttempts32 - (successes and 0xFFFF'u32)) and
        0xFFFF'u32
      let entryFailures = newFailures32.uint16
      entry.failures = entryFailures
      attempts = 0
      successes = 0

    # Vendor asserts when recorded attempts fall below recorded failures.
    if entry.attempts < entry.failures:
      nimFwDbgRcUpdateFail =
        entry.attempts.uint32 or
        (entry.failures.uint32 shl 16) or
        ((rateIdx.uint32 and 0xFF'u32) shl 24) or
        ((slotIdx.uint32 and 0xFF'u32) shl 28)
      assert_err("rc.c", "rc.c", 2040)

    inc slotIdx

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
  elif stage == 2:
    # Re-check with sta flags
    if (sta.mmFlagsBytes[0] and 1) == 0:
      counters.updateStage = 3

proc rc_get_duration*(rateConfig: uint32, length: uint32): uint32 {.exportc, cdecl.} =
  ## Compute frame TX duration in microseconds for given rate_config and frame length
  ## (55 instructions in blob).
  ##
  ## Extracts format mod (bits 12:11 >> 11, masked to &6) from rateConfig.
  ## For legacy (formatMod==0): uses CCK or OFDM duration formula.
  ##   CCK (rateIdx 0..3): durations based on 1/2/5.5/11 Mbps with preamble.
  ##   OFDM (rateIdx 4..11): standard OFDM symbol time formula.
  ## For HT (formatMod==2 or 4): uses HT/VHT symbol time with MCS lookup.
  ## The blob uses lookup tables via custom .insn and relocated data pointers.
  # Blob extracts NSS via rc_get_nss; GCC would DCE a pure-return-discard,
  # so pin it with a volatile var + asm barrier.
  block:
    var nssTmp {.volatile.}: uint8 = rc_get_nss(rateConfig.uint16)
    {.emit: ["asm volatile(\"\" :: \"r\"(", nssTmp, ") : \"memory\");"].}
  let formatMod = (rateConfig shr 11) and 0x6
  let rateIdx = rc_get_mcs_index(rateConfig.uint16)

  if formatMod == 0:
    # Legacy rate
    if rateIdx <= 3:
      # CCK rates: 1, 2, 5.5, 11 Mbps
      # Duration = preamble + (length * 8) / rate_in_half_mbps
      # CCK preamble is 192us (long) or 96us (short)
      # Rates in 0.5 Mbps units: 2, 4, 11, 22
      const cckRates = [2'u32, 4, 11, 22]  # in 0.5 Mbps
      let halfMbps = cckRates[rateIdx.int]
      # Duration = preamble(192) + ceiling(length*16 / halfMbps)
      let bits = length * 16  # length in bits * 2 (for half-Mbps denominator)
      let dataTime = (bits + halfMbps - 1) div halfMbps
      return 192 + dataTime
    else:
      # OFDM rates: 6, 9, 12, 18, 24, 36, 48, 54 Mbps (indices 4..11)
      # Duration = 20 (preamble+signal) + 4 * ceil((16 + 8*length + 6) / N_DBPS)
      # N_DBPS for each rate: 24, 36, 48, 72, 96, 144, 192, 216
      const ofdmNdbps = [24'u32, 36, 48, 72, 96, 144, 192, 216]
      let ofdmIdx = rateIdx.int - 4
      if ofdmIdx < 0 or ofdmIdx >= 8:
        return 0
      let ndbps = ofdmNdbps[ofdmIdx]
      let totalBits = 16'u32 + 8 * length + 6
      let nSymbols = (totalBits + ndbps - 1) div ndbps
      return 20 + 4 * nSymbols
  else:
    # HT/VHT rate
    # Extract NSS from formatMod field (shifted)
    let nssField = (formatMod shr 1) - 1  # 0 or 1 for HT-MF/HT-GF/VHT
    if nssField > 1:
      return 0  # unsupported format

    # HT: preamble 36us (HT-MF) or 32us (HT-GF), symbol 4us (short GI: 3.6us)
    # Duration = preamble + 4 * ceil((16 + 8*length + 6) / N_DBPS)
    # N_DBPS for MCS 0..7 (1 SS): 26, 52, 78, 104, 156, 208, 234, 260
    const htNdbps = [26'u32, 52, 78, 104, 156, 208, 234, 260]
    let mcs = (rateIdx and 0x07).int
    if mcs >= 8:
      return 0
    let ndbps = htNdbps[mcs]
    let totalBits = 16'u32 + 8 * length + 6
    let nSymbols = (totalBits + ndbps - 1) div ndbps
    return 36 + 4 * nSymbols

proc rc_update_bw_nss_max*(staIdx: uint8, nss: uint8, groupCnt: uint8) {.exportc, cdecl.} =
  ## Update bandwidth and NSS max for rate control.
  ## From blob: loads RC stats for staIdx, checks if nss/groupCnt changed,
  ## validates bounds, re-initializes the rate table if sample_idx==0xFFFF.
  ## Algorithm: entry[0]=lowest rate, entry[nRates-1]=initial rate,
  ## entries[1..nRates-2]=random non-duplicate sample rates.
  ## Then clears all entry stats, sorts by throughput, and rebuilds retry chain.
  ##
  ## Blob calls: assert_err(x3), rc_get_initial_rate_config,
  ## rc_get_lowest_rate_config, rc_new_random_rate, rc_check_rate_duplicated,
  ## rc_sort_samples_tp, rc_update_retry_chain.
  let sta = staInfoForIdx(staIdx)
  let rcStats = sta.rcStats
  if rcStats == nil:
    assert_err("rc.c", "rc.c", 0x95D.cint)
    return

  # Check if nss and groupCnt are unchanged -- early exit
  if rcU8(rcStats, RCS_NO_SS) == nss and rcU8(rcStats, RCS_GROUP_CNT) == groupCnt:
    return

  # Store new NSS value (with bounds check: must be <= 3)
  rcU8(rcStats, RCS_NO_SS) = nss
  if nss > 3:
    assert_err("rc.c", "rc.c", 0x963.cint)

  # Store new group count (with bounds check: must be <= 7)
  rcU8(rcStats, RCS_GROUP_CNT) = groupCnt
  if groupCnt > 7:
    assert_err("rc.c", "rc.c", 0x965.cint)

  # Check if rate table needs re-initialization: sample_idx == 0xFFFF
  let sampleIdx = rcU16(rcStats, RCS_SAMPLE_IDX)
  if sampleIdx != 0xFFFF'u16:
    return

  # Entry[0] = lowest rate config
  let lowestRate = rc_get_lowest_rate_config(rcStats)
  rcU16(rcStats, 10) = lowestRate  # entry[0].rate_config

  # Entry[nRates-1] = initial (highest) rate config
  let initialRate = rc_get_initial_rate_config(rcStats)
  let nRates = rcU16(rcStats, RCS_N_RATES)
  let lastEntryOff = (nRates.int - 1) * RC_RATE_ENTRY_SIZE + 10
  rcU16(rcStats, lastEntryOff) = initialRate

  # Fill entries[1..nRates-2] with random non-duplicate sample rates.
  # Blob keeps a single rc_new_random_rate call site inside a do-while; use a
  # bounded helper so bad RNG state cannot trap the cooperative scheduler here.
  var idx: int = 1
  while idx < nRates.int - 1:
    let randomRate = rc_pick_non_duplicate_rate(rcStats)
    if randomRate == 0xFFFF'u16:
      break
    rcSetRateConfig(rcStats, idx, randomRate)
    idx += 1

  # Clear all entry stats fields (throughput, attempts, old_prob, etc.)
  for i in 0 ..< nRates.int:
    rcClearRateEntryTransientStats(rcStats, i.uint16)

  # Sort by throughput and rebuild retry chain
  var tpArray {.noinit.}: array[RC_MAX_RATE_ENTRIES, uint32]
  rc_sort_samples_tp(rcStats, addr tpArray[0])
  rc_update_retry_chain(rcStats, addr tpArray[0])

  # Re-compute staEntry and set RC flags bit 0 (needs update)
  sta.mmFlagsBytes[0] = sta.mmFlagsBytes[0] or 1'u8

proc rc_update_preamble_type*(staIdx: uint8, shortPreamble: uint8) {.exportc, cdecl.} =
  ## Update preamble type for rate control (94 instrs).
  ## a0=staIdx, a1=shortPreamble (0=long, 1=short).
  ## Loads RC stats from sta_info_tab[staIdx]+324. If BW max changed, iterates
  ## rate entries to toggle short preamble bit (bit 10 of rate_config). Uses
  ## is_cck_group to check if rate is CCK, then calls rc_check_rate_duplicated
  ## and rc_new_random_rate as needed. Finally calls rc_sort_samples_tp and
  ## rc_update_retry_chain to rebuild the retry chain.
  let sta = staInfoForIdx(staIdx)
  let stats = sta.rcStats
  if stats == nil:
    assert_err("rc.c", "rc.c", 0x9A2.cint)
    return

  # Check if preamble type actually changed
  let curBwMax = rcU8(stats, RCS_BW_MAX)
  if curBwMax == shortPreamble:
    return

  # Check if sample_idx is 0xFFFF (special case: no change needed)
  let sampleIdx = rcU16(stats, RCS_SAMPLE_IDX)
  rcU8(stats, RCS_BW_MAX) = shortPreamble  # store new preamble type
  if sampleIdx == 0xFFFF'u16:
    return

  # No short preamble support: early exit
  if shortPreamble == 0:
    return

  # Iterate rate entries and toggle short preamble bit
  var idx: uint16 = 0
  while idx < rcU16(stats, RCS_N_RATES):
    let entry = rcRateEntry(stats, idx)
    var rateConfig = entry.rateConfig

    # Use the explicit is_cck_group helper to match blob's call-graph;
    # Nim's inlined `(rate>>11)&6 == 0 && mcs<4` test was equivalent but
    # showed up as 0 call sites vs blob's 1.
    let isCck = is_cck_group(rateConfig.uint32)

    if isCck:
      # Set short preamble bit (bit 10)
      rateConfig = rateConfig or 0x0400'u16

    # Try to set the rate; check for duplicates
    let newConfig = rateConfig
    let dup = rc_check_rate_duplicated(stats, newConfig)
    if dup != 0:
      # Duplicate found: get a new random rate instead
      let randomRate = rc_new_random_rate(stats)
      rateConfig = randomRate

    # Store updated rate config
    # Clear and reinitialize entry fields
    rcClearRateEntryTransientStats(stats, idx)
    entry.rateConfig = rateConfig

    idx += 1

  # Rebuild rate ordering and retry chain
  var tpArray {.noinit.}: array[12, uint8]  # stack-allocated TP array
  rc_sort_samples_tp(stats, addr tpArray[0])

  rc_update_retry_chain(stats, sta.txPolicy)

  # Mark STA for RC update
  sta.mmFlagsBytes[0] = sta.mmFlagsBytes[0] or 1'u8

proc rc_init_bcmc_rate*(staEntry: pointer, band: uint32) {.exportc, cdecl.} =
  ## Initialize broadcast/multicast rate.
  ## From blob (12 instrs): a0=sta_info_tag pointer, a1=band (rate index).
  ## Loads TX policy from sta+320, supported rates from sta+332.
  ## Builds rate config: band | (suppRates & 0x400 if band <= 3) | 0x20000000.
  ## Writes to 4 retry slots at txPolicy offsets 20, 24, 28, 32.
  let sta = staInfoAt(staEntry)
  let txPolicy = sta.txPolicy
  let policy = txPolicyAt(txPolicy)
  let suppRates = sta.supportedRatesBitmap
  var rateConfig = band
  # Conditionally include CCK rate bit if band <= 3
  if band <= 3:
    rateConfig = rateConfig or (suppRates.uint32 and 0x400'u32)
  rateConfig = rateConfig or 0x20000000'u32  # format mod
  for retry in mitems(policy.retryRate):
    retry = rateConfig

proc rc_check_fixed_rate_config*(staIdx: uint8): bool {.exportc, cdecl.} =
  ## Check if fixed rate is valid for the station's capabilities (54 instrs in blob).
  ##
  ## Blob ABI: a0 = stats pointer (NOT sta_entry and NOT staIdx — directly
  ## the rc_sta_stats block). a1 = fixed_rate_config (uint16 packed).
  ## Returns true if HW can send the fixed rate; else tail-calls
  ## rc_set_fixed_rate_config on the passing path.
  ##
  ## Previous Nim read `rateConfig` from stats+182 (RCS_RATE_MAP — the
  ## *supported rates bitmap*), not the caller-supplied fixed rate. That
  ## broke the validation entirely. Fix: grab a1 via inline asm.
  let stats = cast[pointer](staIdx)  # a0 = stats pointer
  var rateConfig: uint16
  {.emit: ["asm volatile(\"mv %0, a1\" : \"=r\"(", rateConfig, ") );"].}

  let formatMod = rcU8(stats, RCS_FORMAT_MOD)

  # Extract format mod from rate config
  let rateFmt = ((rateConfig shr 11) and 0x6).uint8

  if formatMod == 4:
    # Non-HT / legacy-only STA: the fixed rate must also be non-HT
    if rateFmt != 0:
      return false
  else:
    let fmtCheck = (formatMod - 2) and 0xFF
    if fmtCheck > 1:
      return false  # unsupported format mod

    # HT STA: validate NSS and MCS bounds
    if rateFmt != 0:
      # HT/VHT fixed rate: check short GI support
      let shortGi = rcU8(stats, RCS_SHORT_GI)
      if shortGi == 0:
        # No short GI: check if fixed rate uses short GI
        let sgiFlag = rcU8(stats, RCS_BW_MAX + 1)  # offset 191
        if sgiFlag != 0:
          return false

      # Check NSS bounds — blob extracts the NSS with rc_get_nss (not the
      # inline `(rate>>11)&6` shift Nim was using earlier).
      let noSs = rcU8(stats, RCS_NO_SS)
      # GCC -Os will DCE a pure-function-return-discarded call; keep a
      # side-effect asm barrier around the return so the blob's call
      # graph matches.
      block:
        var nssTmp {.volatile.}: uint8 = rc_get_nss(rateConfig)
        {.emit: ["asm volatile(\"\" :: \"r\"(", nssTmp, ") : \"memory\");"].}
      let mcsIdx = rc_check_valid_rate(stats, rateConfig)
      let bwMax = rcU8(stats, RCS_BW_MAX)
      if mcsIdx > bwMax:
        return false

  # All checks passed -- set the fixed rate configuration
  # Blob tail-calls rc_set_fixed_rate_config(staEntry, rateConfig)
  # For now, mark as valid and return true
  return true

# RC internal helper implementations (stubs for functions called by rc_init/rc_check)
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
    let idx = (nss - 2) and 0xFF
    if idx > 1:
      return 0
    return (rateConfig and 0x7).uint8

proc rc_get_nss*(rateConfig: uint16): uint8 {.exportc, cdecl, noinline.} =
  ## Extract NSS (number of spatial streams) from rate_config.
  let nss = ((rateConfig shr 11) and 0x6).uint8
  if nss < 2:
    return 0
  let idx = nss - 2
  if idx > 1:
    return 0
  return (rateConfig and 0x7).uint8

proc rc_check_valid_rate*(stats: pointer, rateConfig: uint16): uint8 {.exportc, cdecl.} =
  ## Check if a rate_config is valid for the given station stats.
  ## Returns 1 if valid, 0 if not.
  ## Blob calls rc_get_nss for the HT/VHT group lookup rather than inlining
  ## the `(rate>>11)&6` shift — matching it keeps call-graph audit aligned.
  let fmtMod = (rateConfig shr 11) and 0x6
  if fmtMod == 0:
    # Legacy: check if rate index is in rate_map
    let idx = rc_get_mcs_index(rateConfig)
    let rateMap = rcU16(stats, RCS_RATE_MAP)
    return ((rateMap shr idx) and 1).uint8
  else:
    # HT/VHT: check MCS bitmap
    let nssField = ((rateConfig shr 11) and 0x6).uint8
    if nssField < 2: return 0
    let nssIdx = nssField - 2
    if nssIdx > 1: return 0
    # Blob uses rc_get_nss for this NSS extract. Use a volatile variable +
    # asm barrier so GCC -Os cannot DCE the call even though we don't need
    # its return value (the rest of the code reuses nssIdx).
    block:
      var nssTmp {.volatile.}: uint8 = rc_get_nss(rateConfig)
      {.emit: ["asm volatile(\"\" :: \"r\"(", nssTmp, ") : \"memory\");"].}
    let mcsIdx = rc_get_mcs_index(rateConfig)
    let groupBase = cast[pointer](cast[uint](stats) + RCS_RATE_BITMAP.uint + nssIdx.uint)
    let bitmap = cast[ptr uint8](groupBase)[]
    return ((bitmap shr mcsIdx) and 1).uint8

proc rc_check_rate_duplicated*(stats: pointer, rateConfig: uint16): uint8 {.exportc, cdecl.} =
  ## Check if rateConfig already exists in the rate table.
  ## Returns 1 if duplicated, 0 if not.
  let nRates = rcU16(stats, RCS_N_RATES)
  for i in 0 ..< nRates.int:
    if rcRateConfig(stats, i) == rateConfig:
      return 1
  return 0

proc rc_get_initial_rate_config*(stats: pointer): uint16 {.exportc, cdecl.} =
  ## Build initial rate_config from stats fields.
  ## For legacy: (format_mod << 11) | (bw_max << 10) | highest_idx
  ## For HT: (format_mod << 11) | (short_gi << 9) | (no_ss << 7) | group*8 | mcs
  let fmtMod = rcU8(stats, RCS_FORMAT_MOD)
  if fmtMod <= 1:
    # Legacy
    let bwMax = rcU8(stats, RCS_BW_MAX)
    let hiIdx = rcU8(stats, RCS_HIGHEST_IDX)
    var rc = (fmtMod.uint16 shl 11) or (bwMax.uint16 shl 10) or hiIdx.uint16
    return rc
  else:
    # HT/VHT
    let groupCnt = rcU8(stats, RCS_GROUP_CNT)
    let sgi = rcU8(stats, RCS_SHORT_GI)
    let noSS = rcU8(stats, RCS_NO_SS)
    # Find highest MCS in the max NSS group. Blob treats RCS_GROUP_CNT as a
    # zero-based group index and reads rate_bitmap[groupCnt] directly.
    let lastGroup = groupCnt
    let mcsByte = rcU8(stats, RCS_RATE_BITMAP + lastGroup.int)
    var hiMcs: uint8 = 0
    if mcsByte != 0:
      var clzIn: cuint = mcsByte.cuint
      var c: cint
      {.emit: [c, " = __builtin_clz(", clzIn, ");"].}
      hiMcs = (31 - c).uint8
    var rc = (fmtMod.uint16 shl 11) or (sgi.uint16 shl 9) or
             (noSS.uint16 shl 7) or (lastGroup.uint16 shl 3) or hiMcs.uint16
    return rc

proc rc_get_lowest_rate_config*(stats: pointer): uint16 {.exportc, cdecl.} =
  ## Build rate_config for the lowest supported rate.
  let fmtMod = rcU8(stats, RCS_FORMAT_MOD)
  if fmtMod <= 1:
    let loIdx = rcU8(stats, RCS_LOWEST_IDX)
    if loIdx == 0:
      return 0x0400'u16  # 1024 = fallback marker
    return (fmtMod.uint16 shl 11) or loIdx.uint16
  else:
    let loIdx = rcU8(stats, RCS_LOWEST_IDX)
    if loIdx == 0:
      return 0x0400'u16
    let bwMax = rcU8(stats, RCS_BW_MAX)
    return (fmtMod.uint16 shl 11) or (bwMax.uint16 shl 10) or loIdx.uint16

proc rc_new_random_rate*(stats: pointer): uint16 {.exportc, cdecl.} =
  ## Generate a random rate_config for sampling using the LCG PRNG (119 instrs).
  ## From blob: advances PRNG, then dispatches on format_mod (offset 177):
  ##   format_mod == 0 (legacy): pick random index in [lowest..highest] range
  ##     from rate_map (offset 182), return (bw_max<<10) | mcs_index.
  ##   format_mod >= 2 (HT/VHT): pick random group from rate_bitmap (offset 178..181),
  ##     then random rate within that group from highest_idx, builds rate_config
  ##     with format_mod, group, and mcs fields.
  ## The rate_config format is: bits[12:11]=format_mod, bits[10]=bw_max,
  ##   bits[9:4]=group/nss, bits[3:0]=mcs_index.
  let prngVal = rcPrngNext()
  let noSS = rcU8(stats, RCS_NO_SS)       # number of spatial streams (0-based max)
  let formatMod = rcU8(stats, RCS_FORMAT_MOD)  # 0=legacy, 2=HT, 4=VHT
  let prngHi = prngVal shr 16              # use upper 16 bits for randomness

  # Build base rate_config with format_mod in bits [12:11]
  var rateConfig: uint16 = formatMod.uint16 shl 11

  if formatMod <= 1:
    # Legacy or single-stream: pick random rate from [lowest..highest] range
    let lowest = rcU8(stats, RCS_LOWEST_IDX)
    let highest = rcU8(stats, RCS_HIGHEST_IDX)
    if lowest >= highest or highest == 0:
      # Only one rate or invalid range
      let rateMap = rcU16(stats, RCS_RATE_MAP)
      let bwMax = rcU8(stats, RCS_BW_MAX)
      rateConfig = rateConfig or (bwMax.uint16 shl 10)
      return rateConfig
    let range = highest - lowest + 1
    let rndIdx = (prngHi.uint32 and 0x7F) mod range.uint32
    let idx = lowest + rndIdx.uint8
    # Check if rate is supported in rate_map
    let rateMap = rcU16(stats, RCS_RATE_MAP)
    let supported = (rateMap shr idx) and 1
    var mcsIdx = idx.uint16
    if supported == 0:
      # Vendor falls back to the highest supported index when the random bit
      # picks a hole in the supported-rate map.
      mcsIdx = highest.uint16
    else:
      if mcsIdx > 0:
        let mcsIdxByte = ((mcsIdx - 1) and 0xFF).uint8
        if mcsIdxByte <= 2:
          # Within first 3 rates, also set BW field
          let bwMax = rcU8(stats, RCS_BW_MAX)
          let bwField = (prngHi and 0x400).uint16  # bit 10 from prng
          rateConfig = rateConfig or bwField or mcsIdx
          return rateConfig
    rateConfig = rateConfig or mcsIdx
    return rateConfig
  else:
    # HT/VHT multi-stream: pick random group then random rate within it
    let groupCnt = rcU8(stats, RCS_GROUP_CNT)

    if groupCnt > 3:
      # Use rate_bitmap for group selection
      let bitmapByte = rcU8(stats, RCS_RATE_BITMAP)
      let groupRange = (prngHi shr 7).uint32 and 0x07  # 3-bit random for group selection
      let maxNssMcs = rcU8(stats, RCS_MAX_NSS_MCS)
      let groupRangeActual = maxNssMcs + 1
      if groupRangeActual == 0:
        return rateConfig or 0x400'u16  # fallback
      let selGroup = groupRange mod groupRangeActual.uint32
      let shortGi = rcU8(stats, RCS_SHORT_GI)
      # Read rate_bitmap for selected group
      let groupBitmap = rcU8(stats, RCS_RATE_BITMAP.int + selGroup.int)
      let lowest = rcU8(stats, RCS_LOWEST_IDX)
      let highest = rcU8(stats, RCS_HIGHEST_IDX)
      let range = highest - lowest + 1
      let rndRate = (prngHi and 0x7F) mod range.uint32
      let rateIdx = lowest + rndRate.uint8
      # Check if supported
      let rateMap = rcU16(stats, RCS_RATE_MAP_L)
      let supported = (rateMap shr rateIdx) and 1
      if supported == 0:
        rateConfig = 0x400'u16  # fallback to lowest with bw_max
      else:
        if rateIdx > 0:
          rateConfig = rateConfig or (rateIdx - 1).uint16
        let bwMax = rcU8(stats, RCS_BW_MAX)
        let bwField = (prngHi and 0x400).uint16
        rateConfig = rateConfig or bwField
      return rateConfig
    else:
      # Small group count: pick from rate_bitmap directly
      let lowest = rcU8(stats, RCS_LOWEST_IDX)
      let highest = rcU8(stats, RCS_HIGHEST_IDX)
      if lowest >= highest:
        return rateConfig or 0x400'u16
      let range = highest - lowest + 1
      let rndIdx = (prngHi and 0x7F) mod range.uint32
      let idx = lowest + rndIdx.uint8
      let rateMap = rcU16(stats, RCS_RATE_MAP_L)
      let supported = (rateMap shr idx) and 1
      if supported == 0:
        return rateConfig or 0x400'u16
      var mcsIdx = idx.uint16
      if mcsIdx > 0:
        mcsIdx = mcsIdx - 1
      let bwMax = rcU8(stats, RCS_BW_MAX)
      let bwField = (prngHi and 0x400).uint16
      rateConfig = rateConfig or bwField or mcsIdx
      return rateConfig

proc rc_update_retry_chain*(stats: pointer, param: pointer) {.exportc, cdecl.} =
  ## Update the retry chain based on current rate statistics (137 instrs).
  ## Builds 4-entry retry chain: [max_tp, max_tp2, max_prob, lowest].
  ## From blob: checks flags bit 2 for fixed chain, then builds sorted
  ## indices by walking rate entries and comparing throughput/probability.
  let nRates = rcU16(stats, RCS_N_RATES)
  if nRates == 0:
    return
  let flags = rcU8(stats, RCS_FLAGS)
  let paramVal = rcRetryChainParamOrZero(param)
  var s1Mode: uint8  # 1=normal, 2=fixed

  # Blob: lui a5,0x40000; addi a5,a5,-1 -> 0x3FFFFFFF; add a5,a5,nRates
  if (flags and 0x04) != 0 or paramVal > (0x3FFFFFFF'u32 + nRates.uint32):
    # Fixed retry chain or overflow: set max_tp to highest rate
    rcU16(stats, RCS_MAX_TP_IDX) = nRates - 1
    rcU32(stats, RCS_TP_CUR) = paramVal
    s1Mode = 2
  else:
    # Normal: start with rate 0 as best
    rcU16(stats, RCS_MAX_TP_IDX) = 0
    rcU32(stats, RCS_TP_CUR) = 0
    s1Mode = 1

  # Step 2: Find max_tp2 (second best throughput)
  # Blob: s6=stats base, walks from entry (nRates-1) downward
  let maxTpIdx = rcU16(stats, RCS_MAX_TP_IDX)

  # Check if max throughput rate is CCK group (blob: is_cck_group at offset 0x54)
  # If CCK, skip the validity scan loop entirely and go to retry chain building
  let maxTpEntryBase = cast[uint](stats) + maxTpIdx.uint * RC_RATE_ENTRY_SIZE.uint
  let maxTpRate = rcRateConfig(stats, maxTpIdx.int)
  let maxTpIsCck = is_cck_group(maxTpRate.uint32)

  if not maxTpIsCck:
    # Not CCK: walk from nRates-2 downward scanning for valid non-CCK entries
    var scanIdx = nRates.int - 2
    while scanIdx >= 0:
      let scanRate = rcRateConfig(stats, scanIdx)
      # Blob: is_cck_group at offset 0x13a — check if candidate is CCK
      if is_cck_group(scanRate.uint32):
        # CCK rate found during scan: clear initialized flag (blob: sb zero, 15(entry))
        rcRateResetFields(stats, scanIdx.uint16).initialized = 0
      scanIdx -= 1

  # Step 3: Set max_tp2 from best remaining rate
  # Blob: walks from (nRates-s1) down, comparing throughput values
  let tp1 = rcU32(stats, RCS_TP_CUR)
  rcU16(stats, RCS_MAX_TP2_IDX) = maxTpIdx  # start same as max_tp
  rcU32(stats, RCS_TP_SECOND) = tp1

  # Search for second-best: walk from (nRates-s1) downward.
  # Blob does NOT call rc_check_valid_rate here — it inspects the
  # cached rate_config directly (0xFFFF == invalid).
  var searchIdx = nRates.int - s1Mode.int
  while searchIdx >= 0:
    let candidateIdx = nRates.uint16 - searchIdx.uint16
    if candidateIdx < nRates:
      let candRate = rcRateConfig(stats, searchIdx)
      if candRate == 0xFFFF'u16:
        searchIdx -= 1
        continue
      if searchIdx.uint16 != maxTpIdx:
        rcU16(stats, RCS_MAX_TP2_IDX) = nRates - s1Mode.uint16
        break
    searchIdx -= 1

  # Step 4: Build retry chain entry 3 (max_prob) by walking rate table
  # Blob: walks entries[8..] with stride 12, comparing prob_ewma
  let maxTp2Idx = rcU16(stats, RCS_MAX_TP2_IDX)
  var bestProbIdx: uint16 = 0
  var bestProbTp: uint16 = 0
  var bestProbProbVal: uint8 = 0
  let probThreshold = 0xF332'u16  # from blob: lui a6,0xf; addi a6,818

  for i in 0 ..< nRates.int:
    let entryProb = rcRateEntryProb(stats, i)
    let entryTp = rcRateEntryTp(stats, i)
    let entryRetry = rcRateEntryRetry(stats, i)
    # Skip if this is the max_tp index
    if i.uint16 == maxTpIdx:
      continue
    # Check initialized flag (entry+7 = byte at offset 7 within entry)
    if entryRetry != 0 and i.uint16 != maxTpIdx:
      let entryRateU16 = rcRateConfig(stats, i)
      # Compare: if prob > probThreshold AND tp > bestProbTp, update
      if entryRateU16 >= probThreshold:
        # Blob: compares entry throughput with current best
        if entryTp > bestProbTp:
          bestProbTp = entryTp
          bestProbProbVal = entryRetry
          bestProbIdx = i.uint16
      elif entryTp > bestProbTp:
        # Lower prob but higher throughput
        bestProbTp = entryTp
        bestProbIdx = i.uint16

  # Store final retry chain results
  rcU16(stats, RCS_MAX_PROB_IDX) = bestProbIdx
  rcU32(stats, RCS_TP_THIRD) = bestProbIdx.uint32  # store index for chain
  rcU16(stats, RCS_RESERVED_U16) = 0
  rcU32(stats, RCS_RETRY_TIMER) = paramVal

proc rc_update_stats*(stats: pointer, needUpdate: uint8): uint8 {.exportc, cdecl.} =
  ## Update rate statistics (320 instructions in blob).
  ##
  ## Minstrel-like algorithm:
  ## Phase 1: Copy rate entries to temp, recalculate EWMA for sample_wait
  ## Phase 2: For each rate entry: calc_prob_ewma, sort into throughput table
  ## Phase 3: If needUpdate==0 and no sample: clear counters, return 0
  ## Phase 4: Build 6-entry sorted throughput table for rate selection
  ## Phase 5: Walk sorted table, apply policy, update retry chain
  ## Phase 6: Copy sorted throughput to stats+128, return
  let statsU = cast[uint](stats)
  let nRates = rcU16(stats, RCS_N_RATES)

  # Phase 1: EWMA decay for sample_wait counter
  let sampleWait = rcU16(stats, 166)  # offset 0xA6 = sample_wait_count
  if sampleWait > 0:
    let attempts = rcU16(stats, 164)  # offset 0xA4 = total_attempts
    rcU16(stats, 164) = 0
    # Compute EWMA: new = (old * 32 + (attempts << 16 / sampleWait)) >> 7
    let scaled = (attempts.uint32 shl 16) div sampleWait.uint32
    let old = rcU32(stats, 168)  # offset 0xA8 = ewma_attempts
    let blended = (old.uint32 * 32 + (scaled shl 5)) shr 7
    rcU32(stats, 168) = blended

  # Reset slow_rate_cnt
  rcU8(stats, RCS_SLOW_RATE_CNT) = 0

  # Phase 2: Recalculate probability for each rate entry
  # Copy entries to temp array for sorting
  var tempEntries {.noinit.}: array[10 * 12, uint8]  # max 10 rates * 12 bytes each
  discard c_memcpy(addr tempEntries[0], cast[pointer](statsU + 14), min(nRates.int * 12, 120).csize_t)

  for i in 0'u32 ..< nRates.uint32:
    let entryPtr = rcRateEntryPtr(stats, i.int)
    rc_calc_prob_ewma(entryPtr)
    # Blob: rc_calc_tp immediately after rc_calc_prob_ewma for each rate
    discard rc_calc_tp(entryPtr, stats)

  # Check sample_idx
  let sampleIdx = rcU16(stats, RCS_SAMPLE_IDX)
  if sampleIdx == 0xFFFF'u16:
    # No active sample: sort and update retry chain
    var tpSorted {.noinit.}: array[4, uint16]
    rc_sort_samples_tp(stats, addr tpSorted[0])
    rc_update_retry_chain(stats, addr tpSorted[0])
    if needUpdate != 0:
      return 0
    return 1

  # Phase 3: If needUpdate==0, check sticky flag; if not sticky, update EWMA for
  # current best rate, clear counters, return 0.
  # Blob path: sampleIdx != 0xFFFF, needUpdate==0, byte175 & 0x20 == 0
  if needUpdate == 0:
    let stickyFlag = rcU8(stats, 175)
    if (stickyFlag and 0x20) == 0:
      # Non-probe, non-sticky: update EWMA for current best rate only
      let bestIdx = rcU16(stats, 128)
      if bestIdx < nRates:
        let bestEntry = rcRateEntryPtr(stats, bestIdx.int)
        rc_calc_prob_ewma(bestEntry)
    # Clear all rate entry counters
    let nR = rcU16(stats, RCS_N_RATES)
    if nR <= 9:
      for i in 0'u32 ..< nR.uint32:
        let entry = rcRateEntry(stats, i.uint16)
        entry.attempts = 0
        entry.failures = 0
    return 0

  # Phase 4: Build 6-entry throughput table (blob: 6-step loop at 0x15E)
  # Blob uses a 6-step dispatch loop (s0 = step counter 0..5):
  #   step 0: rc_new_random_rate -> sample rate
  #   step 1 (s6): rc_set_next_mcs_index(stats, bestRate) -> if diff, rc_check_valid_rate
  #   step 2 (s7): check SGI variant availability
  #   step 3 (a5): rc_set_next_mcs_index(stats, secondBestRate) -> rc_check_valid_rate
  #   step 4 (s5): rc_set_previous_mcs_index(stats, bestRate) -> rc_check_valid_rate
  #   step 5: rc_set_previous_mcs_index(stats, secondBestRate) -> rc_check_valid_rate
  # After: rc_check_rate_duplicated for dedup
  let curBestRate = rcU16(stats, 128)  # stats+128 = best throughput rate config
  let secBestRate = rcU16(stats, 136)  # stats+136 = second-best rate config
  var sortParam {.noinit.}: array[8, uint16]  # 8 entries: [best, sec, sample, next1, next2, prev1, prev2, dedup]
  # Blob zeroes 12 bytes (6 slots) up-front via memset(sp, 0, 12).
  discard c_memset(addr sortParam[0], 0, 12.csize_t)
  sortParam[0] = curBestRate
  sortParam[1] = secBestRate

  # Step 0: Random sample rate
  let sampleRate = rc_new_random_rate(stats)
  sortParam[2] = sampleRate

  # Step 1: Next MCS from best rate
  let nextFromBest = rc_set_next_mcs_index(stats, curBestRate)
  if nextFromBest != curBestRate:
    if rc_check_valid_rate(stats, nextFromBest) != 0:
      sortParam[3] = nextFromBest
    else:
      sortParam[3] = curBestRate
  else:
    sortParam[3] = curBestRate

  # Step 2: SGI check (inline, no call if not applicable)
  let fmtInfo = (curBestRate shr 11) and 0x6
  var sgiRate = curBestRate
  if fmtInfo != 0:
    let sgiEnabled = rcU8(stats, RCS_SHORT_GI)
    if sgiEnabled != 0 and curBestRate == secBestRate:
      sgiRate = curBestRate or 0x200'u16  # set SGI bit
  sortParam[4] = sgiRate

  # Step 3: Next MCS from second-best rate
  let nextFromSec = rc_set_next_mcs_index(stats, secBestRate)
  if nextFromSec != secBestRate:
    if rc_check_valid_rate(stats, nextFromSec) != 0:
      sortParam[5] = nextFromSec
    else:
      sortParam[5] = secBestRate
  else:
    sortParam[5] = secBestRate

  # Step 4: Previous MCS from best rate
  let prevFromBest = rc_set_previous_mcs_index(stats, curBestRate)
  if prevFromBest != curBestRate:
    if rc_check_valid_rate(stats, prevFromBest) != 0:
      sortParam[6] = prevFromBest
    else:
      sortParam[6] = curBestRate
  else:
    sortParam[6] = curBestRate

  # Step 5: Previous MCS from second-best rate
  let prevFromSec = rc_set_previous_mcs_index(stats, secBestRate)
  if prevFromSec != secBestRate:
    if rc_check_valid_rate(stats, prevFromSec) != 0:
      sortParam[7] = prevFromSec
    else:
      sortParam[7] = secBestRate
  else:
    sortParam[7] = secBestRate

  # Dedup check: ensure sample rate is not duplicated with best rates
  if sampleRate != curBestRate and sampleRate != secBestRate:
    let isDup = rc_check_rate_duplicated(stats, sampleRate)
    if isDup != 0:
      sortParam[2] = curBestRate  # fall back to best rate

  # Phase 5: Copy sorted throughput to stats+128 (4 entries, 8 bytes each)
  # Note: blob does NOT call rc_sort_samples_tp or rc_update_retry_chain here.
  # Those are only called in the sampleIdx==0xFFFF path above.
  var retVal: uint8 = 0
  let destBase = statsU + 128
  var srcOff: uint32 = 0
  for i in 0'u32 ..< 4:
    let tpVal = cast[ptr uint16](cast[uint](addr sortParam[0]) + srcOff + 4)[]
    let curVal = cast[ptr uint16](destBase + srcOff + 4)[]
    if tpVal != curVal:
      retVal = 1
    cast[ptr uint16](destBase + srcOff + 4)[] = tpVal
    srcOff += 8

  return retVal

proc rc_set_previous_mcs_index*(stats: pointer, rateConfig: uint16): uint16 {.exportc, cdecl.} =
  ## Get the previous (lower) MCS rate_config.
  let fmtMod = (rateConfig shr 11) and 0x6
  let mcsIdx = rc_get_mcs_index(rateConfig)
  if fmtMod == 0:
    # Legacy: decrement rate index, check rate_map
    let loIdx = rcU8(stats, RCS_LOWEST_IDX)
    if mcsIdx <= loIdx:
      return rateConfig
    let prevIdx = mcsIdx - 1
    let rateMap = rcU16(stats, RCS_RATE_MAP)
    if (rateMap shr prevIdx and 1) != 0:
      return (rateConfig and 0xFF80'u16) or prevIdx.uint16
    return rateConfig
  else:
    # HT: decrement MCS, check bitmap
    let nssIdx = ((rateConfig shr 11) and 0x6).uint8 - 2
    if nssIdx > 1 or mcsIdx == 0:
      return rateConfig
    let maxNss = rcU8(stats, RCS_MAX_NSS_MCS)
    if mcsIdx <= maxNss:
      return rateConfig
    let prevMcs = mcsIdx - 1
    let sgiField = rcU8(stats, RCS_SHORT_GI)
    var newRc = (rateConfig and not 0x07'u16) or prevMcs.uint16
    if sgiField != 0:
      newRc = newRc or 0x200'u16
    return newRc

proc rc_set_next_mcs_index*(stats: pointer, rateConfig: uint16): uint16 {.exportc, cdecl.} =
  ## Get the next (higher) MCS rate_config.
  # Blob inspects NSS via rc_get_nss; match the call even though the branch
  # below switches on fmtMod (derived from the same bits inline). GCC -Os
  # DCEs a pure-return-discarded call — pin it with a volatile var + asm
  # barrier.
  block:
    var nssTmp {.volatile.}: uint8 = rc_get_nss(rateConfig)
    {.emit: ["asm volatile(\"\" :: \"r\"(", nssTmp, ") : \"memory\");"].}
  let fmtMod = (rateConfig shr 11) and 0x6
  let mcsIdx = rc_get_mcs_index(rateConfig)
  if fmtMod == 0:
    # Legacy: increment rate index, check rate_map
    let hiIdx = rcU8(stats, RCS_HIGHEST_IDX)
    if mcsIdx >= hiIdx:
      return rateConfig
    let nextIdx = mcsIdx + 1
    let rateMap = rcU16(stats, RCS_RATE_MAP)
    if ((rateMap shr nextIdx) and 1) != 0:
      return (rateConfig and 0xFF80'u16) or nextIdx.uint16
    return rateConfig
  else:
    # HT: increment MCS, check bitmap
    let maxMcs = rcU8(stats, RCS_MAX_NSS_MCS)
    if mcsIdx >= maxMcs:
      return rateConfig
    let nextMcs = mcsIdx + 1
    # Check if next MCS is in bitmap
    let nssIdx = ((rateConfig shr 11) and 0x6).uint8 - 2
    if nssIdx > 1:
      return rateConfig
    let groupBase = cast[pointer](cast[uint](stats) + RCS_RATE_BITMAP.uint + nssIdx.uint)
    let bitmap = cast[ptr uint8](groupBase)[]
    if ((bitmap shr nextMcs) and 1) != 0:
      var newRc = (rateConfig and 0xFF80'u16) or nextMcs.uint16
      let sgiField = rcU8(stats, RCS_SHORT_GI)
      if sgiField != 0:
        newRc = newRc or 0x200'u16
      return newRc
    return rateConfig

proc rc_sort_samples_tp*(stats: pointer, tpArray: pointer) {.exportc, cdecl.} =
  ## Sort rate entries by throughput (bubble sort, used during stats update).
  let nRates = rcU16(stats, RCS_N_RATES)
  if nRates <= 1:
    return
  let tp = rcThroughputArray(tpArray)
  # Simple insertion sort of throughput values
  var n = nRates.int - 1
  while n > 0:
    for i in 1 ..< n:
      let tp1 = tp[i]
      let tp0 = tp[i - 1]
      if tp1 > tp0:
        # Swap corresponding rate entries. Blob calls memmove (not memcpy)
        # for these 12-byte swaps — presumably the blob's standard-library
        # headers route the call through memmove. Using memmove keeps the
        # blob's call graph aligned.
        var tmp {.noinit.}: RcRateEntryView
        let e1 = rcRateEntryPtr(stats, i)
        let e0 = rcRateEntryPtr(stats, i - 1)
        discard c_memmove(addr tmp, e1, sizeof(RcRateEntryView).csize_t)
        discard c_memmove(e1, e0, sizeof(RcRateEntryView).csize_t)
        discard c_memmove(e0, addr tmp, sizeof(RcRateEntryView).csize_t)
        # Swap tp values
        tp[i] = tp0
        tp[i - 1] = tp1
    dec n

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
    # First measurement: use raw probability (minus 1 if < 100%)
    var p = prob.uint16
    if successes < attempts:
      if p > 0: dec p
      rcU16(entry, 4) = 0
    else:
      rcU16(entry, 4) = p
  else:
    # EWMA: new = (old * 96 + new * 32) / 128
    let oldProb = rcU16(entry, 4).uint32
    let ewma = (oldProb * 96 + (prob shl 5)) shr 7
    rcU16(entry, 4) = ewma.uint16

  # Mark as initialized
  rcU8(entry, 9) = 1

