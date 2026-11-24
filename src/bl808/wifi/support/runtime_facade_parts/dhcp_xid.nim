when defined(bl808WifiDiagDhcpTxAttempts):
  var dhcpXidSeedSource {.exportc: "nimfw_dbg_dhcp_xid_seed_source".}: uint32

proc bl808_lwip_dhcp_xid_seed(): uint32 {.exportc, cdecl.} =
  var random: uint32
  if os_get_random(cast[ptr uint8](addr random), sizeof(random).csize_t) == 0:
    when defined(bl808WifiDiagDhcpTxAttempts): dhcpXidSeedSource = 1
    return random

  # DHCP needs collision avoidance, not a cryptographic secret. Avoid a
  # shared constant even if TRNG ownership or a sample times out.
  let tick = readMtimeUs()
  var mac: array[6, uint8]
  discard bl_wifi_mac_addr_get(addr mac[0])
  var mixed = cast[uint32](tick) xor uint32(tick shr 32)
  for octet in mac:
    mixed = (mixed xor octet.uint32) * 16777619'u32
  when defined(bl808WifiDiagDhcpTxAttempts): dhcpXidSeedSource = 2
  mixed xor (mixed shr 16)
