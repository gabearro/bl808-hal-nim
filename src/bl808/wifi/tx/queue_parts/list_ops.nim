proc listEmpty(list: pointer): bool {.inline.} =
  coListAt(list).first == nil

proc listPushBack(list, item: pointer) =
  if list == nil or item == nil:
    return
  txHdrView(item).linkNext = nil
  let q = coListAt(list)
  let last = q.last
  if last == nil:
    q.first = item
  else:
    txHdrView(last).linkNext = item
  q.last = item

proc listPopFront(list: pointer): pointer =
  if list == nil:
    return nil
  let q = coListAt(list)
  result = q.first
  if result != nil:
    let next = txHdrView(result).linkNext
    q.first = next
    if next == nil:
      q.last = nil
    txHdrView(result).linkNext = nil
