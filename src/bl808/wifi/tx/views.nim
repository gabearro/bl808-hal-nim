proc zero(p: pointer; n: uint) {.inline.} =
  discard c_memset(p, 0, n.csize_t)

proc copyMem(dest, src: pointer; n: uint) {.inline.} =
  if dest != nil and src != nil and n != 0:
    discard c_memcpy(dest, src, n.csize_t)

template pbufView(p: pointer): ptr PbufView =
  cast[ptr PbufView](p)

template ethernetHeaderAt(p: pointer): ptr EthernetHeaderView =
  cast[ptr EthernetHeaderView](p)

template hostTxDescAt(p: pointer): ptr HostTxDescView =
  cast[ptr HostTxDescView](p)

template coListAt(p: pointer): ptr CoListView =
  cast[ptr CoListView](p)

template hwView(): ptr BlHwView =
  cast[ptr BlHwView](addr wifi_hw)

template vifView(p: pointer): ptr BlVifView =
  cast[ptr BlVifView](p)

template staView(p: pointer): ptr BlStaView =
  cast[ptr BlStaView](p)

template keTxFcView(p: pointer): ptr KeTxFcView =
  cast[ptr KeTxFcView](p)

template txHdrView(p: pointer): ptr TxHdrView =
  cast[ptr TxHdrView](p)

template txbufView(p: pointer): ptr TxbufView =
  cast[ptr TxbufView](p)

template txdescHostView(p: pointer): ptr TxdescHostView =
  cast[ptr TxdescHostView](p)

template ipv4HeaderAt(eth: ptr EthernetHeaderView): ptr Ipv4HeaderView =
  cast[ptr Ipv4HeaderView](addr eth.payload[0])

template byteView(p: pointer): ptr UncheckedArray[uint8] =
  cast[ptr UncheckedArray[uint8]](p)

proc bufferAt(base: pointer; off: uint): pointer {.inline.} =
  cast[pointer](addr byteView(base)[off])

proc txbufHostBuf(p: pointer): pointer {.inline.} =
  cast[pointer](addr txbufView(p).hostBuf[0])

proc txdescHostPad(p: pointer): pointer {.inline.} =
  cast[pointer](addr txdescHostView(p).pad[0])

proc txdescUpperHost(p: pointer): ptr HostTxDescView {.inline.} =
  addr txdescHostView(p).upperHost

proc udpHeaderAt(ip: ptr Ipv4HeaderView): ptr UdpHeaderView {.inline.} =
  let ihlWords = ip.versionIhl and 0x0f'u8
  if ihlWords < 5'u8:
    return nil
  cast[ptr UdpHeaderView](addr ip.optionsAndPayload[(ihlWords - 5'u8).uint * 4'u])
