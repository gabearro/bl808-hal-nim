proc utils_list_concat*(list1, list2: ptr UtilsList) {.exportc, cdecl.} =
  let list1Raw = cast[pointer](list1)
  let list2Raw = cast[pointer](list2)
  if loadPtr(list2Raw, 0) == nil: return
  if loadPtr(list1Raw, 4) != nil: storePtr(loadPtr(list1Raw, 4), 0, loadPtr(list2Raw, 0))
  else: storePtr(list1Raw, 0, loadPtr(list2Raw, 0))
  storePtr(list1Raw, 4, loadPtr(list2Raw, 4))
  utils_list_init(list2)

proc utils_list_cnt*(list: ptr ConstUtilsList): cuint {.exportc, cdecl.} =
  var cur = loadPtr(cast[pointer](list), 0)
  while cur != nil:
    inc result
    cur = loadPtr(cur, 0)

proc utils_list_pool_init*(list: ptr UtilsList; pool: pointer; elmtSize: csize_t; elmtCnt: cuint; defaultValue: pointer) {.exportc, cdecl.} =
  utils_list_init(list)
  var cur = pool
  for _ in 0'u32 ..< elmtCnt.uint32:
    if defaultValue != nil: copyMem(cur, defaultValue, elmtSize.uint) else: zero(cur, elmtSize.uint)
    utils_list_push_back(list, cast[ptr UtilsListHdr](cur))
    cur = ptrAt(cur, elmtSize.uint)
