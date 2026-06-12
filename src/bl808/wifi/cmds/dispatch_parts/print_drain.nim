proc cmdMgrPrint(cmdMgr: pointer) {.cdecl.} =
  discard cmdMgr

proc cmdMgrDrain(cmdMgr: pointer) {.cdecl.} =
  cmdMgrLock(cmdMgr)
  let head = ptrAt(cmdMgr, MgrCmdsOff)
  var node = listNext(head)
  while node != head:
    let nextNode = listNext(node)
    listDel(node)
    storeU32(cmdMgr, MgrQueueSzOff, loadU32(cmdMgr, MgrQueueSzOff) - 1'u32)
    if (loadU16(node, CmdFlagsOff) and RwnxCmdFlagNonblock) == 0'u16:
      osEventSend(loadPtr(node, CmdCompleteOff), 1'u32)
    node = nextNode
  cmdMgrUnlock(cmdMgr)
