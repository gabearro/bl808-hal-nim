## Native Wi-Fi RX DMA ring depth. The default preserves the vendor layout.
const WifiRxRingSlots* {.intdefine.} = 41

static:
  doAssert WifiRxRingSlots in 8 .. 41
