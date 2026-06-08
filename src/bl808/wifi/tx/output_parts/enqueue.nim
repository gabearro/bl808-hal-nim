proc enqueueTxPacket(isSta: cint; p: ptr Pbuf; pbuf: ptr PbufView;
                     eth: ptr EthernetHeaderView; customCfm: ptr BlTxCfm): int8 =
  nimFwDbgTxStaLookupEth = eth.ethertype.uint32 or (pbuf.totLen.uint32 shl 16)
  nimFwDbgTxStaLookupDst0 = cast[ptr uint32](addr eth.dst[0])[]
  nimFwDbgTxStaLookupDst1 = cast[ptr uint16](addr eth.dst[4])[].uint32
  let staId = txCntrlGetStaId(isSta, isBcMc(eth.dst[0]),
                              cast[pointer](addr eth.dst[0]))
  if staId < 0:
    {.emit: """{ extern volatile unsigned int nimfw_dbg_bl_output_drop;
                 nimfw_dbg_bl_output_drop++; }""".}
    bl_os_printf("[TX] Cant find valid sta_id, drop! (is_sta: %d, is_bc_mc: %d, proto: %04x)\r\n",
                 isSta, (if isBcMc(eth.dst[0]): 1 else: 0),
                 eth.ethertype.cint)
    return ErrIf

  let sta = staAt(staId)
  if pbuf_header(p, PbufLinkEncapsulationHlen.int16) != 0'u8:
    bl_os_printf("[TX] Reserve room failed for header\r\n")
    return ErrIf

  let payload = pbuf.payload
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
  txHdrView(txhdr).pbuf = p
  setTxHdrLen(txhdr, pbuf.totLen)
  setTxHdrVifType(txhdr, isSta.uint8)
  setTxHdrStaId(txhdr, staId.uint8)

  pbuf_ref(p)
  bl_os_enter_critical()
  listPushBack(cast[pointer](addr staView(sta).waitingList), txhdr)
  txCntrlStaTrigger = txCntrlStaTrigger or bitSta(staId)
  if txCntrlCheckFc(sta):
    bl_irq_handler()
  bl_os_exit_critical()
  ErrOk
