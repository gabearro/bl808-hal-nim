proc utils_list_init*(list: ptr UtilsList) {.exportc, cdecl.} =
  let raw = cast[pointer](list)
  storePtr(raw, 0, nil)
  storePtr(raw, 4, nil)

proc utils_list_push_back*(list: ptr UtilsList; hdr: ptr UtilsListHdr) {.exportc, cdecl.} =
  let listRaw = cast[pointer](list)
  let hdrRaw = cast[pointer](hdr)
  storePtr(hdrRaw, 0, nil)
  let last = loadPtr(listRaw, 4)
  if last != nil: storePtr(last, 0, hdrRaw) else: storePtr(listRaw, 0, hdrRaw)
  storePtr(listRaw, 4, hdrRaw)

proc utils_list_push_front*(list: ptr UtilsList; hdr: ptr UtilsListHdr) {.exportc, cdecl.} =
  let listRaw = cast[pointer](list)
  let hdrRaw = cast[pointer](hdr)
  storePtr(hdrRaw, 0, loadPtr(listRaw, 0))
  storePtr(listRaw, 0, hdrRaw)
  if loadPtr(listRaw, 4) == nil: storePtr(listRaw, 4, hdrRaw)

proc utils_list_pop_front*(list: ptr UtilsList): ptr UtilsListHdr {.exportc, cdecl.} =
  let listRaw = cast[pointer](list)
  result = cast[ptr UtilsListHdr](loadPtr(listRaw, 0))
  if result != nil:
    let resultRaw = cast[pointer](result)
    storePtr(listRaw, 0, loadPtr(resultRaw, 0))
    if loadPtr(listRaw, 0) == nil: storePtr(listRaw, 4, nil)
    storePtr(resultRaw, 0, nil)

proc utils_list_remove*(list: ptr UtilsList; prev, element: ptr UtilsListHdr) {.exportc, cdecl.} =
  let listRaw = cast[pointer](list)
  let prevRaw = cast[pointer](prev)
  let elementRaw = cast[pointer](element)
  if element == nil: return
  if prev != nil: storePtr(prevRaw, 0, loadPtr(elementRaw, 0))
  elif loadPtr(listRaw, 0) == elementRaw: storePtr(listRaw, 0, loadPtr(elementRaw, 0))
  else: return
  if loadPtr(listRaw, 4) == elementRaw: storePtr(listRaw, 4, prevRaw)
  storePtr(elementRaw, 0, nil)

proc utils_list_extract*(list: ptr UtilsList; hdr: ptr UtilsListHdr) {.exportc, cdecl.} =
  let listRaw = cast[pointer](list)
  let hdrRaw = cast[pointer](hdr)
  var prev: pointer
  var cur = loadPtr(listRaw, 0)
  while cur != nil:
    if cur == hdrRaw:
      utils_list_remove(list, cast[ptr UtilsListHdr](prev), cast[ptr UtilsListHdr](cur))
      return
    prev = cur
    cur = loadPtr(cur, 0)

proc utils_list_find*(list: ptr UtilsList; hdr: ptr UtilsListHdr): cint {.exportc, cdecl.} =
  let listRaw = cast[pointer](list)
  let hdrRaw = cast[pointer](hdr)
  var cur = loadPtr(listRaw, 0)
  while cur != nil:
    if cur == hdrRaw: return 1
    cur = loadPtr(cur, 0)
  0
