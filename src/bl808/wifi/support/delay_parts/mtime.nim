proc readMtimeUs(): uint64 =
  let mtime = cast[ptr UncheckedArray[uint32]](MtimeBase.uint)
  var hi1, lo, hi2: uint32
  while true:
    hi1 = mtime[1]
    lo = mtime[0]
    hi2 = mtime[1]
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
  while int64(now - deadline) < 0:
    rawDelay(32)
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
