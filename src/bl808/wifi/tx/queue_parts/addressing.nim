proc alignPads(packetStart: pointer): uint16 {.inline.} =
  ((4'u - (cast[uint](packetStart) and 3'u)) and 3'u).uint16

proc vifAt(vifIndex: int): pointer {.inline.} =
  cast[pointer](addr hwView().vifs[vifIndex])

proc staAt(stationIndex: int): pointer {.inline.} =
  cast[pointer](addr hwView().stas[stationIndex])

proc staVif(sta: pointer): pointer {.inline.} =
  vifAt(staView(sta).vifIdx.int)
