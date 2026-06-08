type
  CoListView {.packed.} = object
    first*: pointer
    last*: pointer

  BlVifView {.packed.} = object
    reserved0*: array[13, uint8]
    vifIdx*: uint8
    linksNum*: uint8
    fixedStaIdx*: uint8
    fcChan*: uint8
    reserved17*: array[3, uint8]

  BlStaView {.packed.} = object
    waitingList*: CoListView
    pendingList*: CoListView
    macAddr*: array[6, uint8]
    isUsed*: uint8
    staIdx*: uint8
    vifIdx*: uint8
    reserved25*: uint8
    fcPs*: uint8
    qos*: uint8
    reserved28*: array[12, uint8]

  BlHwView {.packed.} = object
    reserved0*: array[48, uint8]
    ipcEnv*: pointer
    reserved52*: array[8, uint8]
    vifs*: array[2, BlVifView]
    stas*: array[NxRemoteStaStoreMax, BlStaView]

  KeTxFcView {.packed.} = object
    vifBits*: uint8
    apFcChan*: uint8
    apFcPsStaBits*: uint8
    staFcChan*: uint8
    staFcPs*: uint8
