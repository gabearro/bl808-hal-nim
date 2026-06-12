proc enqueueTxPacket(isSta: cint; txPbuf: ptr Pbuf; txPbufView: ptr PbufView;
                     ethernetHeader: ptr EthernetHeaderView; customCfm: ptr BlTxCfm): int8 =
  nimFwDbgTxStaLookupEth = ethernetHeader.ethertype.uint32 or (txPbufView.totLen.uint32 shl 16)
  nimFwDbgTxStaLookupDst0 = cast[ptr uint32](addr ethernetHeader.dst[0])[]
  nimFwDbgTxStaLookupDst1 = cast[ptr uint16](addr ethernetHeader.dst[4])[].uint32
  let staId = txCntrlGetStaId(isSta, isBcMc(ethernetHeader.dst[0]),
                              cast[pointer](addr ethernetHeader.dst[0]))
  if staId < 0:
    {.emit: """{ extern volatile unsigned int nimfw_dbg_bl_output_drop;
                 nimfw_dbg_bl_output_drop++; }""".}
    bl_os_printf("[TX] Cant find valid sta_id, drop! (is_sta: %d, is_bc_mc: %d, proto: %04x)\r\n",
                 isSta, (if isBcMc(ethernetHeader.dst[0]): 1 else: 0),
                 ethernetHeader.ethertype.cint)
    return ErrIf

  let sta = staAt(staId)
  if pbuf_header(txPbuf, PbufLinkEncapsulationHlen.int16) != 0'u8:
    bl_os_printf("[TX] Reserve room failed for header\r\n")
    return ErrIf

  let payload = txPbufView.payload
  let alignOffset = alignPads(payload)
  let linkDescLen = alignOffset + TxHdrSize.uint16 + 16'u16
  if linkDescLen > PbufLinkEncapsulationHlen:
    bl_os_printf("[TX] link_header size is %ld vs header %u\r\n",
                 linkDescLen.cint, PbufLinkEncapsulationHlen.cint)
    return ErrBuf

  let txhdr = bufferAt(payload, alignOffset.uint)
  zero(txhdr, TxHdrSize)
  if customCfm != nil:
    copyMem(cast[pointer](addr txHdrView(txhdr).cfmCb), customCfm, TxCfmSize)
  txHdrView(txhdr).pbuf = txPbuf
  setTxHdrLen(txhdr, txPbufView.totLen)
  setTxHdrVifType(txhdr, isSta.uint8)
  setTxHdrStaId(txhdr, staId.uint8)

  pbuf_ref(txPbuf)
  bl_os_enter_critical()
  listPushBack(cast[pointer](addr staView(sta).waitingList), txhdr)
  txCntrlStaTrigger = txCntrlStaTrigger or bitSta(staId)
  if txCntrlCheckFc(sta):
    bl_irq_handler()
  bl_os_exit_critical()
  ErrOk
