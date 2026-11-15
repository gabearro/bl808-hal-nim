proc listInit(list: pointer) {.inline.} =
  let saved = ipcHostIrqSave()
  defer: ipcHostIrqRestore(saved)
  storePtr(list, 0, nil)
  storePtr(list, 4, nil)

proc listPushBack(list, hdr: pointer) {.inline.} =
  if hdr == nil:
    return
  let saved = ipcHostIrqSave()
  defer: ipcHostIrqRestore(saved)
  storePtr(hdr, 0, nil)
  let last = loadPtr(list, 4)
  if last != nil:
    storePtr(last, 0, hdr)
  else:
    storePtr(list, 0, hdr)
  storePtr(list, 4, hdr)

proc listPopFront(list: pointer): pointer {.inline.} =
  let saved = ipcHostIrqSave()
  defer: ipcHostIrqRestore(saved)
  result = loadPtr(list, 0)
  if result != nil:
    let nextHeader = loadPtr(result, 0)
    storePtr(list, 0, nextHeader)
    if nextHeader == nil:
      storePtr(list, 4, nil)
    storePtr(result, 0, nil)

proc listPick(list: pointer): pointer {.inline.} =
  if list == nil: nil else: loadPtr(list, 0)
