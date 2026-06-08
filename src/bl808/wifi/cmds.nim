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
  listInit(ptrAt(cmdMgr, MgrCmdsOff))
  storePtr(cmdMgr, MgrLockOff, osMutexCreate())
  storeU32(cmdMgr, MgrMaxQueueSzOff, RwnxCmdMaxQueued)
  storePtr(cmdMgr, MgrQueueOff, cast[pointer](cmdMgrQueue))
  storePtr(cmdMgr, MgrPrintOff, cast[pointer](cmdMgrPrint))
  storePtr(cmdMgr, MgrDrainOff, cast[pointer](cmdMgrDrain))
  storePtr(cmdMgr, MgrLlindOff, cast[pointer](cmdMgrLlind))
  storePtr(cmdMgr, MgrMsgindOff, cast[pointer](cmdMgrMsgind))
