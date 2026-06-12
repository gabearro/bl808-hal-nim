proc zero(memory: pointer; byteCount: uint) {.inline.} =
  discard c_memset(memory, 0, byteCount.csize_t)

proc copyMem(dest, src: pointer; byteCount: uint) {.inline.} =
  if dest != nil and src != nil and byteCount != 0:
    discard c_memcpy(dest, src, byteCount.csize_t)

template pbufView(packet: pointer): ptr PbufView =
  cast[ptr PbufView](packet)

template ethernetHeaderAt(packet: pointer): ptr EthernetHeaderView =
  cast[ptr EthernetHeaderView](packet)

template hostTxDescAt(txDescriptor: pointer): ptr HostTxDescView =
  cast[ptr HostTxDescView](txDescriptor)

template coListAt(listStorage: pointer): ptr CoListView =
  cast[ptr CoListView](listStorage)

template hwView(): ptr BlHwView =
  cast[ptr BlHwView](addr wifi_hw)

template vifView(vifEntry: pointer): ptr BlVifView =
  cast[ptr BlVifView](vifEntry)

template staView(stationEntry: pointer): ptr BlStaView =
  cast[ptr BlStaView](stationEntry)

template keTxFcView(flowControlEntry: pointer): ptr KeTxFcView =
  cast[ptr KeTxFcView](flowControlEntry)

template txHdrView(txHeader: pointer): ptr TxHdrView =
  cast[ptr TxHdrView](txHeader)

template txbufView(txBuffer: pointer): ptr TxbufView =
  cast[ptr TxbufView](txBuffer)

template txdescHostView(txDescriptor: pointer): ptr TxdescHostView =
  cast[ptr TxdescHostView](txDescriptor)

template ipv4HeaderAt(eth: ptr EthernetHeaderView): ptr Ipv4HeaderView =
  cast[ptr Ipv4HeaderView](addr eth.payload[0])

template byteView(memory: pointer): ptr UncheckedArray[uint8] =
  cast[ptr UncheckedArray[uint8]](memory)

proc bufferAt(base: pointer; byteOffset: uint): pointer {.inline.} =
  cast[pointer](addr byteView(base)[byteOffset])

proc txbufHostBuf(txBuffer: pointer): pointer {.inline.} =
  cast[pointer](addr txbufView(txBuffer).hostBuf[0])

proc txdescHostPad(txDescriptor: pointer): pointer {.inline.} =
  cast[pointer](addr txdescHostView(txDescriptor).hostDescPadding[0])

proc txdescUpperHost(txDescriptor: pointer): ptr HostTxDescView {.inline.} =
  addr txdescHostView(txDescriptor).upperHost

proc udpHeaderAt(ip: ptr Ipv4HeaderView): ptr UdpHeaderView {.inline.} =
  let ihlWords = ip.versionIhl and 0x0f'u8
  if ihlWords < 5'u8:
    return nil
  cast[ptr UdpHeaderView](addr ip.optionsAndPayload[(ihlWords - 5'u8).uint * 4'u])
