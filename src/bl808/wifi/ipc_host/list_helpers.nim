proc listInit(list: pointer) {.inline.} =
  storePtr(list, 0, nil)
  storePtr(list, 4, nil)

proc listPushBack(list, hdr: pointer) {.inline.} =
  if hdr == nil:
    return
  storePtr(hdr, 0, nil)
  let last = loadPtr(list, 4)
  if last != nil:
    storePtr(last, 0, hdr)
  else:
    storePtr(list, 0, hdr)
  storePtr(list, 4, hdr)

proc listPopFront(list: pointer): pointer {.inline.} =
  result = loadPtr(list, 0)
  if result != nil:
    let next = loadPtr(result, 0)
    storePtr(list, 0, next)
    if next == nil:
      storePtr(list, 4, nil)
    storePtr(result, 0, nil)

proc listPick(list: pointer): pointer {.inline.} =
  if list == nil: nil else: loadPtr(list, 0)
