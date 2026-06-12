proc utils_list_init*(list: ptr UtilsList) {.exportc, cdecl.} =
  let listStorage = cast[pointer](list)
  storePtr(listStorage, 0, nil)
  storePtr(listStorage, 4, nil)

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

proc utils_list_remove*(list: ptr UtilsList; previousElement, element: ptr UtilsListHdr) {.exportc, cdecl.} =
  let listRaw = cast[pointer](list)
  let previousElementRaw = cast[pointer](previousElement)
  let elementRaw = cast[pointer](element)
  if element == nil: return
  if previousElement != nil: storePtr(previousElementRaw, 0, loadPtr(elementRaw, 0))
  elif loadPtr(listRaw, 0) == elementRaw: storePtr(listRaw, 0, loadPtr(elementRaw, 0))
  else: return
  if loadPtr(listRaw, 4) == elementRaw: storePtr(listRaw, 4, previousElementRaw)
  storePtr(elementRaw, 0, nil)

proc utils_list_extract*(list: ptr UtilsList; hdr: ptr UtilsListHdr) {.exportc, cdecl.} =
  let listRaw = cast[pointer](list)
  let hdrRaw = cast[pointer](hdr)
  var previousNode: pointer
  var currentNode = loadPtr(listRaw, 0)
  while currentNode != nil:
    if currentNode == hdrRaw:
      utils_list_remove(list, cast[ptr UtilsListHdr](previousNode), cast[ptr UtilsListHdr](currentNode))
      return
    previousNode = currentNode
    currentNode = loadPtr(currentNode, 0)

proc utils_list_find*(list: ptr UtilsList; hdr: ptr UtilsListHdr): cint {.exportc, cdecl.} =
  let listRaw = cast[pointer](list)
  let hdrRaw = cast[pointer](hdr)
  var currentNode = loadPtr(listRaw, 0)
  while currentNode != nil:
    if currentNode == hdrRaw: return 1
    currentNode = loadPtr(currentNode, 0)
  0
