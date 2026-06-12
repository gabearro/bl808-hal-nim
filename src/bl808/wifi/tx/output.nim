include output_parts/protocol_diag
include output_parts/dhcp_tx
include output_parts/enqueue

proc bl_output*(blHw: ptr BlHw; isSta: cint; txPbuf: ptr Pbuf; customCfm: ptr BlTxCfm): int8
    {.exportc, cdecl.} =
  if blHw == nil or txPbuf == nil:
    bl_os_printf("[TX] NULL parameters!\r\n")
    return ErrConn

  let txPbufView = pbufView(cast[pointer](txPbuf))
  let ethernetHeaderPtr = txPbufView.payload
  let ethernetHeader = ethernetHeaderAt(ethernetHeaderPtr)
  let etherType = ethernetHeader.ethertype
  noteTxProtocol(txPbufView, etherType)
  noteDhcpTx(txPbufView, ethernetHeader, etherType)
  if etherType == 0x8e88'u16 or etherType == 0x888e'u16:
    {.emit: """{ extern volatile unsigned int nimfw_dbg_bl_output_eapol;
                 nimfw_dbg_bl_output_eapol++; }""".}
  enqueueTxPacket(isSta, txPbuf, txPbufView, ethernetHeader, customCfm)
