proc clearHostname() =
  for i in 0 ..< wifiMgmr.hostname.len:
    wifiMgmr.hostname[i] = 0.cchar

proc putHostnameChar(pos: var int; ch: char) =
  if pos < wifiMgmr.hostname.len - 1:
    wifiMgmr.hostname[pos] = ch.cchar
    inc pos

proc putHostnameHex(pos: var int; value: uint8) =
  const hex = "0123456789abcdef"
  putHostnameChar(pos, hex[int((value shr 4) and 0x0f'u8)])
  putHostnameChar(pos, hex[int(value and 0x0f'u8)])

proc setHostname(mac: ptr uint8) =
  clearHostname()
  var pos = 0
  for ch in "Bouffalolab_BL808-":
    putHostnameChar(pos, ch)
  putHostnameHex(pos, cast[ptr UncheckedArray[uint8]](mac)[3])
  putHostnameHex(pos, cast[ptr UncheckedArray[uint8]](mac)[4])
  putHostnameHex(pos, cast[ptr UncheckedArray[uint8]](mac)[5])
