type
  WifiKeepaliveStats* = object
    frames*: uint32
    failures*: uint32
    attempts*: uint32
    busy*: uint32
    ackDelta*: uint32
    failDelta*: uint32
    cfmDelta*: uint32
