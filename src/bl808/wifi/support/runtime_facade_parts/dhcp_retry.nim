proc bl808_lwip_dhcp_retry_ms*(xid, nowMs: uint32; tries, state: uint8): uint16
    {.exportc, cdecl.} =
  ## RFC 2131 acquisition backoff, quantized to lwIP's 500 ms fine timer.
  let exponent = min(max(tries.uint32, 1'u32) - 1'u32, 4'u32)
  let base = 4000'u32 shl exponent
  var sample = xid xor nowMs xor (tries.uint32 shl 16) xor state.uint32
  sample = (sample xor (sample shr 16)) * 0x7FEB352D'u32
  sample = sample xor (sample shr 15)
  let slots = if base == 64_000: 3'u32 else: 5'u32
  uint16(base - 1000 + 500 * (sample mod slots))
