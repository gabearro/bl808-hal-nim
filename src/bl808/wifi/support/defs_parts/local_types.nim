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
  SimpleEventGroup = object
    bits: uint32
  SimpleQueue = object
    itemSize: uint32
    depth: uint32
    readIdx: uint32
    writeIdx: uint32
