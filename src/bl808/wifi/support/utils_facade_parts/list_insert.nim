proc utils_list_insert*(list: ptr UtilsList; element: ptr UtilsListHdr; cmp: UtilsListCmp) {.exportc, cdecl.} =
  let listRaw = cast[pointer](list)
  let elementRaw = cast[pointer](element)
  var prev: pointer
  var cur = loadPtr(listRaw, 0)
  while cur != nil and cmp != nil and
      cmp(cast[ptr ConstUtilsListHdr](element), cast[ptr ConstUtilsListHdr](cur)) == 0:
    prev = cur
    cur = loadPtr(cur, 0)
  if prev != nil:
    storePtr(elementRaw, 0, cur)
    storePtr(prev, 0, elementRaw)
    if cur == nil:
      storePtr(listRaw, 4, elementRaw)
  else:
    utils_list_push_front(list, element)

proc utils_list_insert_after*(list: ptr UtilsList; prevElement, element: ptr UtilsListHdr) {.exportc, cdecl.} =
  if prevElement == nil:
    utils_list_push_front(list, element)
  elif utils_list_find(list, prevElement) != 0:
    let listRaw = cast[pointer](list)
    let prevRaw = cast[pointer](prevElement)
    let elementRaw = cast[pointer](element)
    storePtr(elementRaw, 0, loadPtr(prevRaw, 0))
    storePtr(prevRaw, 0, elementRaw)
    if loadPtr(listRaw, 4) == prevRaw: storePtr(listRaw, 4, elementRaw)

proc utils_list_insert_before*(list: ptr UtilsList; nextElement, element: ptr UtilsListHdr) {.exportc, cdecl.} =
  let listRaw = cast[pointer](list)
  let nextRaw = cast[pointer](nextElement)
  let elementRaw = cast[pointer](element)
  var prev: pointer
  var cur = loadPtr(listRaw, 0)
  while cur != nil:
    if cur == nextRaw:
      if prev != nil:
        storePtr(elementRaw, 0, cur)
        storePtr(prev, 0, elementRaw)
      else:
        utils_list_push_front(list, element)
      return
    prev = cur
    cur = loadPtr(cur, 0)
