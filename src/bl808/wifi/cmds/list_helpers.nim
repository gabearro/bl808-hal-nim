proc listNext(list: pointer): pointer {.inline.} = loadPtr(list, 0)
proc listPrev(list: pointer): pointer {.inline.} = loadPtr(list, 4)
proc listSetNext(list, value: pointer) {.inline.} = storePtr(list, 0, value)
proc listSetPrev(list, value: pointer) {.inline.} = storePtr(list, 4, value)

proc listInit(head: pointer) {.inline.} =
  listSetNext(head, head)
  listSetPrev(head, head)

proc listEmpty(head: pointer): bool {.inline.} =
  listNext(head) == head

proc listAddTail(node, head: pointer) {.inline.} =
  let previousTail = listPrev(head)
  listSetNext(node, head)
  listSetPrev(node, previousTail)
  listSetNext(previousTail, node)
  listSetPrev(head, node)

proc listDel(node: pointer) {.inline.} =
  let previousNode = listPrev(node)
  let nextNode = listNext(node)
  listSetNext(previousNode, nextNode)
  listSetPrev(nextNode, previousNode)
