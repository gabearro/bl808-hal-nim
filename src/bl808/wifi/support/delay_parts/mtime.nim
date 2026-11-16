const MtimeSampleAttempts = 8
var lastCoherentMtimeUs: uint64

proc sampleMtimeUs(value: var uint64): bool =
  # One rollover normally needs one retry. Bound incoherent reads too, and
  # publish the RV32 two-word cache atomically with respect to IRQ readers.
  let saved = osEnterCritical()
  defer: osExitCritical(saved)
  for attempt in 0 ..< MtimeSampleAttempts:
    let highBefore = regRead32(MtimeBase + 4)
    let low = regRead32(MtimeBase)
    let highAfter = regRead32(MtimeBase + 4)
    if highBefore == highAfter:
      value = (highBefore.uint64 shl 32) or low.uint64
      lastCoherentMtimeUs = value
      return true
  inc nimWifiDbgMtimeReadFailures
  value = lastCoherentMtimeUs
  false

proc readMtimeUs(): uint64 =
  discard sampleMtimeUs(result)

proc delayFallback(us: uint32) =
  # Preserve the full requested budget when it exceeds one rawDelay call.
  var remaining = us.uint64 * 96'u64 + 2048'u64
  while remaining != 0:
    let chunk = min(remaining, high(uint32).uint64).uint32
    rawDelay(chunk)
    remaining -= chunk.uint64

proc delayMtimeUs(us: uint32) =
  inc nimWifiDbgDelayCalls
  nimWifiDbgDelayLastUs = us
  nimWifiDbgDelayLastStale = 0
  nimWifiDbgDelayLastStartLo = 0
  nimWifiDbgDelayLastNowLo = 0
  if us == 0:
    return
  var now: uint64
  let sampled = sampleMtimeUs(now)
  nimWifiDbgDelayLastStartLo = uint32(now and 0xFFFF_FFFF'u64)
  nimWifiDbgDelayLastNowLo = nimWifiDbgDelayLastStartLo
  if not sampled:
    inc nimWifiDbgDelayFallbacks
    delayFallback(us)
    return
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
  # Widen before scaling so a large request cannot wrap to a small cap.
  var iters: uint32 = 0
  let iterCap = min(us.uint64 * 4'u64 + 4096'u64, 262144'u64).uint32
  while cast[int64](now - deadline) < 0:
    rawDelay(32)
    inc iters
    if iters >= iterCap:
      inc nimWifiDbgDelayFallbacks
      delayFallback(us)
      return
    if not sampleMtimeUs(now):
      inc nimWifiDbgDelayFallbacks
      delayFallback(us)
      return
    nimWifiDbgDelayLastNowLo = uint32(now and 0xFFFF_FFFF'u64)
    if now == last:
      inc staleReads
      nimWifiDbgDelayLastStale = staleReads
      if staleReads > 1024:
        inc nimWifiDbgDelayFallbacks
        delayFallback(us)
        return
    else:
      last = now
      staleReads = 0
