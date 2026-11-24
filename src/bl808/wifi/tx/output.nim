include output_parts/admission
include output_parts/protocol_diag
include output_parts/dhcp_tx
include output_parts/enqueue

proc bl_output*(blHw: ptr BlHw; isSta: cint; txPbuf: ptr Pbuf; customCfm: ptr BlTxCfm): int8
    {.exportc, cdecl.} =
  if blHw == nil or txPbuf == nil:
    bl_os_printf("[TX] NULL parameters!\r\n")
    return ErrConn

  let txPbufView = pbufView(cast[pointer](txPbuf))
  if not txPbufAdmissible(cast[pointer](txPbuf)):
    return ErrBuf
  let ethernetHeaderPtr = txPbufView.payload
  let ethernetHeader = ethernetHeaderAt(ethernetHeaderPtr)
  let etherType = ethernetHeader.ethertype
  when defined(bl808WifiDiagTcpPath):
    let tcp = observeTcpPath(ethernetHeaderPtr, txPbufView.len.uint, txPbufView.totLen.uint)
    logTcpPath(tcp, tcpTxOutput)
  noteTxProtocol(txPbufView, etherType)
  noteDhcpTx(txPbufView, ethernetHeader, etherType)
  if etherType == 0x8e88'u16 or etherType == 0x888e'u16:
    {.emit: """{ extern volatile unsigned int nimfw_dbg_bl_output_eapol;
                 nimfw_dbg_bl_output_eapol++; }""".}
  let rc = enqueueTxPacket(isSta, txPbuf, txPbufView, ethernetHeader, customCfm)
  when defined(bl808WifiDiagTcpPath):
    if rc != 0: logTcpPath(tcp, tcpTxRejected, cast[uint32](rc.int32))
  rc
