proc txPush(sta, txdescHost, ptxbuf, txhdr: pointer) =
  zero(txdescHostPad(txdescHost), 208)
  let txbuf = ptxbuf
  let txbufBuf = txbufHostBuf(txbuf)
  var p: pointer = nil
  var ethhdr: pointer

  if txHdrView(txhdr).pbuf != txbuf:
    p = txHdrView(txhdr).pbuf
    ethhdr = bufferAt(pbufView(p).payload, PbufLinkEncapsulationHlen.uint)
  else:
    ethhdr = bufferAt(txbufBuf, PbufLinkEncapsulationHlen.uint)

  let staO = staView(sta)
  let hostDesc = txdescUpperHost(txdescHost)
  let eth = ethernetHeaderAt(ethhdr)
  copyMem(addr hostDesc.ethDest[0], addr eth.dst[0], EthAlen)
  copyMem(addr hostDesc.ethSrc[0], addr eth.src[0], EthAlen)
  hostDesc.ethertype = eth.ethertype
  hostDesc.vifType = txHdrVifType(txhdr)
  hostDesc.packetLen = txHdrLen(txhdr) - LinkOffsetLen
  hostDesc.vifIdx = vifView(staVif(sta)).vifIdx
  hostDesc.staId = staO.staIdx
  hostDesc.tid = if staO.qos != 0'u8: 0'u8 else: 0xff'u8
  hostDesc.packetAddr = 0x1111_1111'u32
  hostDesc.flags = 0

  var newTxhdr = txhdr
  var totalLen: uint16
  if txHdrView(txhdr).pbuf != txbuf:
    let alignSrc = alignPads(pbufView(p).payload)
    let alignDst = alignPads(txbufBuf)
    newTxhdr = bufferAt(txbufBuf, alignDst.uint)
    var q = p
    var loop = 0
    totalLen = 0
    while q != nil:
      let qView = pbufView(q)
      let qPayload = qView.payload
      let qLen = qView.len
      if loop == 0:
        copyMem(bufferAt(txbufBuf, PbufLinkEncapsulationHlen.uint),
                bufferAt(qPayload, PbufLinkEncapsulationHlen.uint),
                (qLen - PbufLinkEncapsulationHlen).uint)
      else:
        copyMem(bufferAt(txbufBuf, totalLen.uint), qPayload, qLen.uint)
      totalLen = totalLen + qLen
      inc loop
      q = qView.next
    copyMem(newTxhdr, txhdr, TxHdrSize)
    txHdrView(newTxhdr).pbuf = txbuf
    discard pbuf_free(cast[ptr Pbuf](p))
  else:
    totalLen = txHdrLen(newTxhdr)

  hostDesc.pbufChainedPtr = cast[uint](bufferAt(txbufBuf, LinkOffsetLen.uint)).uint32
  hostDesc.pbufChainedLen = (totalLen - LinkOffsetLen).uint32
  hostDesc.statusAddr = cast[uint](addr txHdrView(newTxhdr).status).uint32
  hostDesc.pbufAddr = cast[uint](txbuf).uint32
  ipc_host_txdesc_push(hwView().ipcEnv, txbuf)
