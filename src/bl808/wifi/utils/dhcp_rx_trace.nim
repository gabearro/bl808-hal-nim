var
  nimfw_dbg_lwip_dhcp_recv_count {.importc.}: uint32
  nimfw_dbg_lwip_dhcp_recv_code {.importc.}: uint32
  nimfw_dbg_lwip_dhcp_recv_meta {.importc.}: uint32
  dhcpRxTraceCount {.exportc: "nimfw_dbg_dhcp_rx_trace_count".}: uint32
  dhcpRxTraceLog {.exportc: "nimfw_dbg_dhcp_rx_trace_log".}: array[8, array[5, uint32]]

const DhcpRecvNoClient = 1'u32 # Pinned SDK DHCP trace code.

proc pbufCopyDhcpPrefix(p: ptr Pbuf; dest: pointer; length, offset: uint16): uint16
  {.importc: "pbuf_copy_partial", header: "lwip/pbuf.h".}

proc parseChainedDhcpRx(packet: ptr Pbuf; prefixLen: uint16): DhcpWireTrace {.noinline.} =
  var prefix {.noInit.}: array[DhcpTracePrefixSize, uint8]
  let copied = pbufCopyDhcpPrefix(packet, addr prefix[0], prefixLen, 0)
  parseDhcpWire(addr prefix[0], copied.uint, packet.tot_len.uint, true)

proc observeDhcpRx(packet: ptr Pbuf): DhcpWireTrace =
  let prefixLen = min(packet.tot_len, DhcpTracePrefixSize.uint16)
  if prefixLen < 42: return
  if packet.len >= prefixLen:
    return parseDhcpWire(packet.payload, prefixLen.uint, packet.tot_len.uint, true)
  if packet.len >= 24 and
      (loadBe16(packet.payload, 12) != 0x0800 or loadU8(packet.payload, 23) != 17):
    return
  parseChainedDhcpRx(packet, prefixLen)

proc dhcpRecvCount(): uint32 = volatileLoad(addr nimfw_dbg_lwip_dhcp_recv_count)

proc logDhcpRx(wire: DhcpWireTrace; stage, before, after: uint32) =
  let delta = after - before
  var code, meta: uint32
  if delta == 1:
    code = volatileLoad(addr nimfw_dbg_lwip_dhcp_recv_code)
    # Older SDK trace patches leave recv_meta stale on this exit.
    if code != DhcpRecvNoClient:
      meta = volatileLoad(addr nimfw_dbg_lwip_dhcp_recv_meta)
  let saved = csrReadMstatus()
  disableInterrupts()
  {.emit: "__asm__ volatile(\"\" ::: \"memory\");".}
  # Publish only complete rows. A changed receive count invalidates the sample.
  let single = delta == 1 and dhcpRecvCount() == after
  let tag = wire.kind.uint32 or (wire.xidValid.uint32 shl 8) or
    (stage shl 9) or (single.uint32 shl 11)
  dhcpRxTraceLog[dhcpRxTraceCount and 7] =
    [wire.xid, tag, delta, (if single: code else: 0), (if single: meta else: 0)]
  inc dhcpRxTraceCount
  inc nimFwDbgTcpipInputDhcpRx
  {.emit: "__asm__ volatile(\"\" ::: \"memory\");".}
  if (saved and 8) != 0: enableInterrupts()
