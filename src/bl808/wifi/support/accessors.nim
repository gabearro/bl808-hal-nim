template ptrAt(base: pointer; byteOffset: uint): pointer =
  cast[pointer](cast[uint](base) + byteOffset)
proc loadPtr(base: pointer; byteOffset: uint): pointer {.inline.} = cast[ptr pointer](ptrAt(base, byteOffset))[]
proc storePtr(base: pointer; byteOffset: uint; value: pointer) {.inline.} = cast[ptr pointer](ptrAt(base, byteOffset))[] = value
proc loadU8(base: pointer; byteOffset: uint): uint8 {.inline.} = cast[ptr uint8](ptrAt(base, byteOffset))[]
proc storeU8(base: pointer; byteOffset: uint; value: uint8) {.inline.} = cast[ptr uint8](ptrAt(base, byteOffset))[] = value
proc loadI8(base: pointer; byteOffset: uint): int8 {.inline.} = cast[ptr int8](ptrAt(base, byteOffset))[]
proc storeU16(base: pointer; byteOffset: uint; value: uint16) {.inline.} = cast[ptr uint16](ptrAt(base, byteOffset))[] = value
proc loadU16(base: pointer; byteOffset: uint): uint16 {.inline.} = cast[ptr uint16](ptrAt(base, byteOffset))[]
proc storeU32(base: pointer; byteOffset: uint; value: uint32) {.inline.} = cast[ptr uint32](ptrAt(base, byteOffset))[] = value
proc loadU32(base: pointer; byteOffset: uint): uint32 {.inline.} = cast[ptr uint32](ptrAt(base, byteOffset))[]
proc loadI32(base: pointer; byteOffset: uint): int32 {.inline.} = cast[ptr int32](ptrAt(base, byteOffset))[]
proc storeI32(base: pointer; byteOffset: uint; value: int32) {.inline.} = cast[ptr int32](ptrAt(base, byteOffset))[] = value
proc regRead32(reg: uint32): uint32 {.inline.} = cast[ptr uint32](reg.uint)[]
proc regWrite32(reg, value: uint32) {.inline.} = cast[ptr uint32](reg.uint)[] = value
proc regUpdate32(reg, mask, value: uint32) {.inline.} =
  let registerValue = regRead32(reg)
  regWrite32(reg, (registerValue and not mask) or (value and mask))
proc zero(memory: pointer; byteCount: uint) {.inline.} = discard c_memset(memory, 0, byteCount.csize_t)
proc copyMem(dest, src: pointer; byteCount: uint) {.inline.} = discard c_memcpy(dest, src, byteCount.csize_t)
proc wifiHwRaw(): pointer {.inline.} = cast[pointer](addr wifi_hw)
proc mgmrRaw(): pointer {.inline.} = cast[pointer](addr wifiMgmr)
proc staIface(): pointer {.inline.} = ptrAt(mgmrRaw(), MgmrStaOff)
proc apIface(): pointer {.inline.} = ptrAt(mgmrRaw(), MgmrApOff)
proc ifaceNetif(iface: pointer): pointer {.inline.} =
  when defined(bl808WifiRealLwip):
    if iface == staIface():
      cast[pointer](addr bl808_real_sta_netif)
    elif iface == apIface():
      cast[pointer](addr bl808_real_ap_netif)
    else:
      nil
  else:
    ptrAt(iface, WifiIfaceNetifOff)
proc netifHwaddr(netif: pointer): ptr uint8 {.inline.} =
  when defined(bl808WifiRealLwip):
    realNetifHwaddr(cast[ptr Netif](netif))
  else:
    cast[ptr uint8](ptrAt(netif, NetifHwaddrOff))
proc vifAt(vifIndex: uint): pointer {.inline.} = ptrAt(ptrAt(wifiHwRaw(), BlHwVifTableOff), vifIndex * BlVifSize)
