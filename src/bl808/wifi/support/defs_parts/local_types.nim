## Local bare-metal support structures.

type
  ScanDiagItem = object
    used: uint8
    ssidLen: uint8
    ssid: array[33, uint8]
    bssid: array[6, uint8]
    channel: uint8
    rssi: int8
    auth: uint8
    cipher: uint8
  ScanCacheItem = object
    used: uint8
    failCount: uint8
    ssidLen: uint8
    ssid: array[33, uint8]
    bssid: array[6, uint8]
    channel: uint8
    rssi: int8
    auth: uint8
    cipher: uint8
  OsObjectHeader = object
    users: uint32
    deleted: bool
  OsEventWaiter = object
    next: ptr OsEventWaiter
    mask: uint32
    clearOnExit, waitForAll, ready: bool
    value: uint32
  SimpleEventGroup = object
    header: OsObjectHeader
    bits: uint32
    waiters: ptr OsEventWaiter
  SimpleSemaphore = object
    header: OsObjectHeader
    available: bool
  SimpleMutex = object
    header: OsObjectHeader
  SimpleTimer = object
    header: OsObjectHeader
    next: ptr SimpleTimer
    callback, arg: pointer
    deadlineUs, periodUs: uint64
    active, periodic, running: bool
  SimpleTimeout = object
    lastMilliseconds: uint64
  SimpleQueue = object
    header: OsObjectHeader
    itemSize: uint32
    depth: uint32
    readIdx: uint32
    writeIdx: uint32
    count: uint32
