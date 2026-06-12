proc findIeSsid(ieBuffer: pointer; ieBufferLength: cint;
                ssidOut: pointer; ssidLengthOut: ptr cint): cint =
  var ieOffset = 0
  var ieCursor = ieBuffer
  while ieOffset < ieBufferLength:
    let elementLength = loadU8(ieCursor, 1).cint
    if loadU8(ieCursor, 0) == IeIdSsid:
      if elementLength > 32:
        return -1
      ssidLengthOut[] = elementLength
      copyMem(ssidOut, ptrAt(ieCursor, 2), elementLength.uint)
      storeU8(ssidOut, elementLength.uint, 0)
      return 0
    ieOffset += elementLength + 2
    ieCursor = ptrAt(ieCursor, (elementLength + 2).uint)
  -1

proc findIeDs(ieBuffer: pointer; ieBufferLength: cint; channelOut: ptr uint8): cint =
  var ieOffset = 0
  var ieCursor = ieBuffer
  while ieOffset < ieBufferLength:
    let elementLength = loadU8(ieCursor, 1).cint
    if loadU8(ieCursor, 0) == IeIdDsChannel:
      if elementLength > 32:
        return -1
      channelOut[] = loadU8(ieCursor, 2)
      return 0
    ieOffset += elementLength + 2
    ieCursor = ptrAt(ieCursor, (elementLength + 2).uint)
  -1
