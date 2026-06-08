include output_parts/protocol_diag
include output_parts/dhcp_tx
include output_parts/enqueue

proc bl_output*(blHw: ptr BlHw; isSta: cint; p: ptr Pbuf; customCfm: ptr BlTxCfm): int8
    {.exportc, cdecl.} =
  if blHw == nil or p == nil:
    bl_os_printf("[TX] NULL parameters!\r\n")
    return ErrConn

  let pbuf = pbufView(cast[pointer](p))
  let ethhdr = pbuf.payload
  let eth = ethernetHeaderAt(ethhdr)
  let proto = eth.ethertype
  noteTxProtocol(pbuf, eth, proto)
  noteDhcpTx(pbuf, eth, proto)
  if proto == 0x8e88'u16 or proto == 0x888e'u16:
    {.emit: """{ extern volatile unsigned int nimfw_dbg_bl_output_eapol;
                 nimfw_dbg_bl_output_eapol++; }""".}
  enqueueTxPacket(isSta, p, pbuf, eth, customCfm)
