proc findIeSsid(buffer: pointer; length: cint; outSsid: pointer; ssidLen: ptr cint): cint =
  var i = 0
  var p = buffer
  while i < length:
    let elemLen = loadU8(p, 1).cint
    if loadU8(p, 0) == IeIdSsid:
      if elemLen > 32:
        return -1
      ssidLen[] = elemLen
      copyMem(outSsid, ptrAt(p, 2), elemLen.uint)
      storeU8(outSsid, elemLen.uint, 0)
      return 0
    i += elemLen + 2
    p = ptrAt(p, (elemLen + 2).uint)
  -1

proc findIeDs(buffer: pointer; length: cint; outChannel: ptr uint8): cint =
  var i = 0
  var p = buffer
  while i < length:
    let elemLen = loadU8(p, 1).cint
    if loadU8(p, 0) == IeIdDsChannel:
      if elemLen > 32:
        return -1
      outChannel[] = loadU8(p, 2)
      return 0
    i += elemLen + 2
    p = ptrAt(p, (elemLen + 2).uint)
  -1
