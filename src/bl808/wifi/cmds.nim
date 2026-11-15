## Nim replacement for the BL808 WiFi host command manager.

include cmds/layout
include cmds/types

include cmds/host_interfaces
include cmds/accessors
include cmds/list_helpers
include cmds/os_wrappers

include cmds/queue

include cmds/dispatch

proc bl_cmd_mgr_init*(cmdMgr: pointer) {.exportc, cdecl.} =
  if cmdMgr == nil:
    return
  if loadPtr(cmdMgr, MgrLockOff) == nil:
    storePtr(cmdMgr, MgrLockOff, osMutexCreate())
  cmdMgrLock(cmdMgr)
  defer: cmdMgrUnlock(cmdMgr)
  if loadU32(cmdMgr, MgrStateOff) == RwnxCmdMgrStateDraining: return
  let head = ptrAt(cmdMgr, MgrCmdsOff)
  if listNext(head) != nil and not listEmpty(head):
    cmdMgrAbort(cmdMgr, nil, Epipe)
    if not listEmpty(head): return
  if cmdMailboxOwner(cmdMgr) != nil:
    storeU32(cmdMgr, MgrStateOff, RwnxCmdMgrStateCrashed)
    return
  listInit(ptrAt(cmdMgr, MgrCmdsOff))
  storeU32(cmdMgr, MgrStateOff, 0)
  storeU32(cmdMgr, MgrQueueSzOff, 0)
  storeU32(cmdMgr, MgrMaxQueueSzOff, RwnxCmdMaxQueued)
  storePtr(cmdMgr, MgrQueueOff, cast[pointer](cmdMgrQueue))
  storePtr(cmdMgr, MgrPrintOff, cast[pointer](cmdMgrPrint))
  storePtr(cmdMgr, MgrDrainOff, cast[pointer](cmdMgrDrain))
  storePtr(cmdMgr, MgrLlindOff, cast[pointer](cmdMgrLlind))
  storePtr(cmdMgr, MgrMsgindOff, cast[pointer](cmdMgrMsgind))

var nimFwDbgCmdMgrRecovered* {.exportc: "nimfw_dbg_cmd_mgr_recovered".}: uint32

proc wifiCmdMgrReady*(cmdMgr: pointer): bool {.exportc, cdecl.} =
  if cmdMgr == nil: return false
  cmdMgrLock(cmdMgr)
  defer: cmdMgrUnlock(cmdMgr)
  let env = loadPtr(cmdMgr, BlHwIpcEnvOff)
  cmdMgrAccepting(cmdMgr) and env != nil and loadPtr(env, CmdIpcSharedOff) != nil

proc wifiCmdMgrRecoverIfCrashed*(cmdMgr: pointer): bool {.exportc, cdecl.} =
  ## Recovery preserves the mailbox sequence and waits for outstanding ACKs.
  if cmdMgr == nil: return false
  cmdMgrLock(cmdMgr)
  defer: cmdMgrUnlock(cmdMgr)
  if loadU32(cmdMgr, MgrStateOff) != RwnxCmdMgrStateCrashed or
      not listEmpty(ptrAt(cmdMgr, MgrCmdsOff)): return false
  let env = loadPtr(cmdMgr, BlHwIpcEnvOff)
  if env == nil or loadPtr(env, CmdIpcSharedOff) == nil or
      cmdMailboxOwner(cmdMgr) != nil: return false
  storeU32(cmdMgr, MgrStateOff, 0)
  inc nimFwDbgCmdMgrRecovered
  true
