proc utils_list_concat*(list1, list2: ptr UtilsList) {.exportc, cdecl.} =
  let list1Raw = cast[pointer](list1)
  let list2Raw = cast[pointer](list2)
  if loadPtr(list2Raw, 0) == nil: return
  if loadPtr(list1Raw, 4) != nil: storePtr(loadPtr(list1Raw, 4), 0, loadPtr(list2Raw, 0))
  else: storePtr(list1Raw, 0, loadPtr(list2Raw, 0))
  storePtr(list1Raw, 4, loadPtr(list2Raw, 4))
  utils_list_init(list2)

proc utils_list_cnt*(list: ptr ConstUtilsList): cuint {.exportc, cdecl.} =
  var currentNode = loadPtr(cast[pointer](list), 0)
  while currentNode != nil:
    inc result
    currentNode = loadPtr(currentNode, 0)

proc utils_list_pool_init*(list: ptr UtilsList; pool: pointer; elmtSize: csize_t; elmtCnt: cuint; defaultValue: pointer) {.exportc, cdecl.} =
  utils_list_init(list)
  var poolElement = pool
  for _ in 0'u32 ..< elmtCnt.uint32:
    if defaultValue != nil: copyMem(poolElement, defaultValue, elmtSize.uint) else: zero(poolElement, elmtSize.uint)
    utils_list_push_back(list, cast[ptr UtilsListHdr](poolElement))
    poolElement = ptrAt(poolElement, elmtSize.uint)
