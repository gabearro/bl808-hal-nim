proc txPush(station, hostTxDescStorage, txBuffer, txHeaderPtr: pointer) =
  zero(txdescHostPad(hostTxDescStorage), 208)
  let txPayloadStorage = txbufHostBuf(txBuffer)
  var sourcePbuf: pointer = nil
  var ethernetFramePtr: pointer

  if txHdrView(txHeaderPtr).pbuf != txBuffer:
    sourcePbuf = txHdrView(txHeaderPtr).pbuf
    ethernetFramePtr = bufferAt(pbufView(sourcePbuf).payload, PbufLinkEncapsulationHlen.uint)
  else:
    ethernetFramePtr = bufferAt(txPayloadStorage, PbufLinkEncapsulationHlen.uint)

  let stationState = staView(station)
  let hostTxDesc = txdescUpperHost(hostTxDescStorage)
  let ethernetHeader = ethernetHeaderAt(ethernetFramePtr)
  copyMem(addr hostTxDesc.ethDest[0], addr ethernetHeader.dst[0], EthAlen)
  copyMem(addr hostTxDesc.ethSrc[0], addr ethernetHeader.src[0], EthAlen)
  hostTxDesc.ethertype = ethernetHeader.ethertype
  hostTxDesc.vifType = txHdrVifType(txHeaderPtr)
  hostTxDesc.packetLen = txHdrLen(txHeaderPtr) - LinkOffsetLen
  hostTxDesc.vifIdx = vifView(staVif(station)).vifIdx
  hostTxDesc.staId = stationState.staIdx
  hostTxDesc.tid = if stationState.qos != 0'u8: 0'u8 else: 0xff'u8
  hostTxDesc.packetAddr = 0x1111_1111'u32
  hostTxDesc.flags = 0

  var pushedTxHeaderPtr = txHeaderPtr
  var totalLen: uint16
  if txHdrView(txHeaderPtr).pbuf != txBuffer:
    let targetPayloadAlignOffset = alignPads(txPayloadStorage)
    pushedTxHeaderPtr = bufferAt(txPayloadStorage, targetPayloadAlignOffset.uint)
    var chainedPbuf = sourcePbuf
    var chainIndex = 0
    totalLen = 0
    while chainedPbuf != nil:
      let chainedPbufView = pbufView(chainedPbuf)
      let chainedPayload = chainedPbufView.payload
      let chainedLen = chainedPbufView.len
      if chainIndex == 0:
        copyMem(bufferAt(txPayloadStorage, PbufLinkEncapsulationHlen.uint),
                bufferAt(chainedPayload, PbufLinkEncapsulationHlen.uint),
                (chainedLen - PbufLinkEncapsulationHlen).uint)
      else:
        copyMem(bufferAt(txPayloadStorage, totalLen.uint), chainedPayload, chainedLen.uint)
      totalLen = totalLen + chainedLen
      inc chainIndex
      chainedPbuf = chainedPbufView.next
    copyMem(pushedTxHeaderPtr, txHeaderPtr, TxHdrSize)
    txHdrView(pushedTxHeaderPtr).pbuf = txBuffer
    discard pbuf_free(cast[ptr Pbuf](sourcePbuf))
  else:
    totalLen = txHdrLen(pushedTxHeaderPtr)

  hostTxDesc.pbufChainedPtr = cast[uint](bufferAt(txPayloadStorage, LinkOffsetLen.uint)).uint32
  hostTxDesc.pbufChainedLen = (totalLen - LinkOffsetLen).uint32
  hostTxDesc.statusAddr = cast[uint](addr txHdrView(pushedTxHeaderPtr).status).uint32
  hostTxDesc.pbufAddr = cast[uint](txBuffer).uint32
  ipc_host_txdesc_push(hwView().ipcEnv, txBuffer)
