proc listEmpty(list: pointer): bool {.inline.} =
  coListAt(list).first == nil

proc listPushBack(list, item: pointer) =
  if list == nil or item == nil:
    return
  txHdrView(item).linkNext = nil
  let txList = coListAt(list)
  let last = txList.last
  if last == nil:
    txList.first = item
  else:
    txHdrView(last).linkNext = item
  txList.last = item

proc listPopFront(list: pointer): pointer =
  if list == nil:
    return nil
  let txList = coListAt(list)
  result = txList.first
  if result != nil:
    let nextPacket = txHdrView(result).linkNext
    txList.first = nextPacket
    if nextPacket == nil:
      txList.last = nil
    txHdrView(result).linkNext = nil
