template ptrAt(base: pointer; off: uint): pointer =
  cast[pointer](cast[uint](base) + off)
proc loadPtr(base: pointer; off: uint): pointer {.inline.} = cast[ptr pointer](ptrAt(base, off))[]
proc storePtr(base: pointer; off: uint; value: pointer) {.inline.} = cast[ptr pointer](ptrAt(base, off))[] = value
proc loadU8(base: pointer; off: uint): uint8 {.inline.} = cast[ptr uint8](ptrAt(base, off))[]
proc storeU8(base: pointer; off: uint; value: uint8) {.inline.} = cast[ptr uint8](ptrAt(base, off))[] = value
proc loadI8(base: pointer; off: uint): int8 {.inline.} = cast[ptr int8](ptrAt(base, off))[]
proc storeU16(base: pointer; off: uint; value: uint16) {.inline.} = cast[ptr uint16](ptrAt(base, off))[] = value
proc loadU16(base: pointer; off: uint): uint16 {.inline.} = cast[ptr uint16](ptrAt(base, off))[]
proc storeU32(base: pointer; off: uint; value: uint32) {.inline.} = cast[ptr uint32](ptrAt(base, off))[] = value
proc loadU32(base: pointer; off: uint): uint32 {.inline.} = cast[ptr uint32](ptrAt(base, off))[]
proc loadI32(base: pointer; off: uint): int32 {.inline.} = cast[ptr int32](ptrAt(base, off))[]
proc storeI32(base: pointer; off: uint; value: int32) {.inline.} = cast[ptr int32](ptrAt(base, off))[] = value
proc regRead32(reg: uint32): uint32 {.inline.} = cast[ptr uint32](reg.uint)[]
proc regWrite32(reg, value: uint32) {.inline.} = cast[ptr uint32](reg.uint)[] = value
proc regUpdate32(reg, mask, value: uint32) {.inline.} =
  let cur = regRead32(reg)
  regWrite32(reg, (cur and not mask) or (value and mask))
proc zero(p: pointer; n: uint) {.inline.} = discard c_memset(p, 0, n.csize_t)
proc copyMem(dest, src: pointer; n: uint) {.inline.} = discard c_memcpy(dest, src, n.csize_t)
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
proc vifAt(idx: uint): pointer {.inline.} = ptrAt(ptrAt(wifiHwRaw(), BlHwVifTableOff), idx * BlVifSize)
