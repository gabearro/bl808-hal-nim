proc alignPads(p: pointer): uint16 {.inline.} =
  ((4'u - (cast[uint](p) and 3'u)) and 3'u).uint16

proc vifAt(idx: int): pointer {.inline.} =
  cast[pointer](addr hwView().vifs[idx])

proc staAt(idx: int): pointer {.inline.} =
  cast[pointer](addr hwView().stas[idx])

proc staVif(sta: pointer): pointer {.inline.} =
  vifAt(staView(sta).vifIdx.int)
