const Bl808RfCalDelayPollLimit = 512

var nimFwDbgRfCalDelayFallbacks* {.exportc: "nimfw_dbg_rf_cal_delay_fallbacks".}: uint32

proc spinBl808RfCountdown(seed: uint32) {.inline.} =
  var remaining {.noinit.}: uint32
  volatileStore(addr remaining, seed)
  while true:
    let count = volatileLoad(addr remaining)
    volatileStore(addr remaining, count - 1'u32)
    if count == 0:
      break

proc waitBl808RfcUs(us: uint32) {.inline.} =
  # rfc_helper.o:wait_us clamps to 24 bits, then scales by 16.
  spinBl808RfCountdown(min(us, 0xFFFFFF'u32) shl 4)

proc waitBl808RfCalUs(us: uint32) =
  # Pinned phyrf_utils.o:udelay waits on MAC TIMLO and executes the
  # volatile countdown once even when the requested interval is zero.
  let deadline = regRead(MACHW_TIMLO_REG) + us
  for _ in 0 ..< Bl808RfCalDelayPollLimit:
    spinBl808RfCountdown(32)
    if cast[int32](regRead(MACHW_TIMLO_REG) - deadline) >= 0:
      return
  # A gated MAC clock must not hang calibration. The platform delay has
  # its own CPU-spin fallback if mtime is also unavailable.
  inc nimFwDbgRfCalDelayFallbacks
  waitRfUs(us)
