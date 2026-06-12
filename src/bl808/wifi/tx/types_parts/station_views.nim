type
  CoListView {.packed.} = object
    first*: pointer
    last*: pointer

  BlVifView {.packed.} = object
    driverPrivatePrefix*: array[8, uint8]
    netifDev*: pointer
    isUp*: uint8
    vifIdx*: uint8
    linksNum*: uint8
    fixedStaIdx*: uint8
    fcChan*: uint8
    staPsMode*: uint8
    driverPrivateTail*: array[2, uint8]

  BlStaView {.packed.} = object
    waitingList*: CoListView
    pendingList*: CoListView
    macAddr*: array[6, uint8]
    isUsed*: uint8
    staIdx*: uint8
    vifIdx*: uint8
    linkState*: uint8
    fcPs*: uint8
    qos*: uint8
    rssi*: int8
    dataRate*: uint8
    rxStatsPadding*: array[2, uint8]
    tsfLo*: uint32
    tsfHi*: uint32

  BlHwView {.packed.} = object
    driverPrivatePrefix*: array[48, uint8]
    ipcEnv*: pointer
    driverPrivateAfterIpc*: array[8, uint8]
    vifs*: array[2, BlVifView]
    stas*: array[NxRemoteStaStoreMax, BlStaView]

  KeTxFcView {.packed.} = object
    vifBits*: uint8
    apFcChan*: uint8
    apFcPsStaBits*: uint8
    staFcChan*: uint8
    staFcPs*: uint8
