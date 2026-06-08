proc txHdrLen(txhdr: pointer): uint16 {.inline.} =
  txHdrView(txhdr).len

proc setTxHdrLen(txhdr: pointer; value: uint16) {.inline.} =
  txHdrView(txhdr).len = value

proc txHdrVifType(txhdr: pointer): uint8 {.inline.} =
  txHdrView(txhdr).vifStaRepush and 0x0f'u8

proc setTxHdrVifType(txhdr: pointer; value: uint8) {.inline.} =
  let hdr = txHdrView(txhdr)
  hdr.vifStaRepush = (hdr.vifStaRepush and 0xf0'u8) or (value and 0x0f'u8)

proc txHdrStaId(txhdr: pointer): uint8 {.inline.} =
  (txHdrView(txhdr).vifStaRepush shr 4) and 0x0f'u8

proc setTxHdrStaId(txhdr: pointer; value: uint8) {.inline.} =
  let hdr = txHdrView(txhdr)
  hdr.vifStaRepush = (hdr.vifStaRepush and 0x0f'u8) or ((value and 0x0f'u8) shl 4)

proc txHdrRepush(txhdr: pointer): uint8 {.inline.} =
  txHdrView(txhdr).repush

proc setTxHdrRepush(txhdr: pointer; value: uint8) {.inline.} =
  txHdrView(txhdr).repush = value
