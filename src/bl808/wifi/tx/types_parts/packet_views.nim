type
  PbufView {.packed.} = object
    next*: pointer
    payload*: pointer
    totLen*: uint16
    len*: uint16

  EthernetHeaderView {.packed.} = object
    dst*: array[6, uint8]
    src*: array[6, uint8]
    ethertype*: uint16
    payload*: UncheckedArray[uint8]

  Ipv4HeaderView {.packed.} = object
    versionIhl*: uint8
    dscpEcn*: uint8
    totalLen*: uint16
    identification*: uint16
    flagsFrag*: uint16
    ttl*: uint8
    protocol*: uint8
    checksum*: uint16
    srcAddr*: uint32
    dstAddr*: uint32
    optionsAndPayload*: UncheckedArray[uint8]

  UdpHeaderView {.packed.} = object
    srcPort*: uint16
    dstPort*: uint16
    len*: uint16
    checksum*: uint16
    payload*: UncheckedArray[uint8]
