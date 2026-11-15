proc cmdMgrPrint(cmdMgr: pointer) {.cdecl.} =
  discard cmdMgr

proc cmdMgrDrain(cmdMgr: pointer) {.cdecl.} =
  cmdMgrLock(cmdMgr)
  cmdMgrAbort(cmdMgr, nil, Epipe)
  cmdMgrUnlock(cmdMgr)
