type
  CmdQueueProc = proc(cmdMgr, cmd: pointer): cint {.cdecl.}
  CmdLlindProc = proc(cmdMgr, cmd: pointer): cint {.cdecl.}
  MsgCbProc = proc(blHw, cmd, msg: pointer): cint {.cdecl.}
  CmdMsgindProc = proc(cmdMgr, msg, cb: pointer): cint {.cdecl.}
  CmdVoidProc = proc(cmdMgr: pointer) {.cdecl.}

  EventGroupCreateProc = proc(): pointer {.cdecl.}
  EventGroupDeleteProc = proc(event: pointer) {.cdecl.}
  EventGroupSendProc = proc(event: pointer; bits: uint32): uint32 {.cdecl.}
  EventGroupWaitProc = proc(event: pointer; bits: uint32; clearOnExit, waitAll: cint;
                            ticks: uint32): uint32 {.cdecl.}
  MutexCreateProc = proc(): pointer {.cdecl.}
  MutexLockProc = proc(mutex: pointer): int32 {.cdecl.}
  MutexUnlockProc = proc(mutex: pointer): int32 {.cdecl.}
  FreeProc = proc(p: pointer) {.cdecl.}
