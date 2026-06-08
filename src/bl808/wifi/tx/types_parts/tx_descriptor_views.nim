type
  TxHdrView {.packed.} = object
    linkNext*: pointer
    cfmCb*: pointer
    cfmArg*: pointer
    status*: uint32
    pbuf*: pointer
    len*: uint16
    vifStaRepush*: uint8
    repush*: uint8

  TxbufView {.packed.} = object
    reserved0*: array[4, uint8]
    hostBuf*: UncheckedArray[uint8]

  HostTxDescView {.packed.} = object
    pbufAddr*: uint32
    packetAddr*: uint32
    packetLen*: uint16
    reserved10*: array[2, uint8]
    statusAddr*: uint32
    ethDest*: array[6, uint8]
    ethSrc*: array[6, uint8]
    ethertype*: uint16
    reserved30*: array[12, uint8]
    tid*: uint8
    vifIdx*: uint8
    vifType*: uint8
    staId*: uint8
    flags*: uint16
    pbufChainedPtr*: uint32
    reserved52*: array[12, uint8]
    pbufChainedLen*: uint32

  TxdescHostView {.packed.} = object
    reserved0*: array[12, uint8]
    pad*: array[4, uint8]
    upperHost*: HostTxDescView
