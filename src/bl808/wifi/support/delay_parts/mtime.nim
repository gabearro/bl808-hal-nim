proc readMtimeUs(): uint64 =
  # The mtime counter MUST be read with VOLATILE loads. A plain
  # `cast[ptr UncheckedArray[uint32]]` deref is non-volatile, so the optimizer
  # collapses the hi/lo/hi consistency loop into two loads AND hoists them out
  # of delayMtimeUs's wait loop — `now` then never advances and the delay spins
  # forever with interrupts masked (the silent all-core hang, root-caused via
  # JTAG: PC stuck in rawDelay<-delayMtimeUs while HW mtime kept advancing).
  # regRead32 uses a volatile load (see accessors.nim), so every iteration
  # re-reads the live counter instead of a hoisted cached value.
  var hi1, lo, hi2: uint32
  while true:
    hi1 = regRead32(MtimeBase + 4)
    lo = regRead32(MtimeBase)
    hi2 = regRead32(MtimeBase + 4)
    if hi1 == hi2:
      break
  (uint64(hi1) shl 32) or uint64(lo)

proc delayMtimeUs(us: uint32) =
  inc nimWifiDbgDelayCalls
  nimWifiDbgDelayLastUs = us
  var now = readMtimeUs()
  nimWifiDbgDelayLastStartLo = uint32(now and 0xFFFF_FFFF'u64)
  var last = now
  let deadline = now + us.uint64
  var staleReads: uint32
  # ABSOLUTE iteration cap — independent of the mtime value. During a WiFi
  # reconnect the RF/PHY reset can gate the mtime clock domain from the M0's
  # side: the CPU's readMtimeUs() then FREEZES at one value (JTAG-confirmed:
  # now stuck at 0x61ad2dcf while the HW counter advanced to 0x691a...), so the
  # deadline is never reached. The `now == last` stale-fallback below does NOT
  # fire if the frozen/gated read jitters even slightly (staleReads keeps
  # resetting), so it is not a sufficient guard. Bound the TOTAL spin: at ~1
  # rawDelay(32) per iteration, cap so even a fully-frozen clock exits after a
  # bounded, still-generous nop delay instead of hanging the whole M0 forever.
  # Cap scales with the requested us but is clamped so a huge `us` can't spin
  # unbounded either.
  var iters: uint32 = 0
  let iterCap = min(us * 4'u32 + 4096'u32, 262144'u32)
  while int64(now - deadline) < 0:
    rawDelay(32)
    inc iters
    if iters >= iterCap:
      inc nimWifiDbgDelayFallbacks
      rawDelay(us * 96'u32 + 2048'u32)
      return
    now = readMtimeUs()
    nimWifiDbgDelayLastNowLo = uint32(now and 0xFFFF_FFFF'u64)
    if now == last:
      inc staleReads
      nimWifiDbgDelayLastStale = staleReads
      if staleReads > 1024:
        inc nimWifiDbgDelayFallbacks
        rawDelay(us * 96'u32 + 2048'u32)
        return
    else:
      last = now
      staleReads = 0
