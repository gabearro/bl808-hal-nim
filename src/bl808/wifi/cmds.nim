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

var nimFwDbgCmdMgrRecovered* {.exportc: "nimfw_dbg_cmd_mgr_recovered".}: uint32

proc wifiCmdMgrRecoverIfCrashed*(cmdMgr: pointer): bool {.exportc, cdecl.} =
  ## If the host command manager latched Crashed — a blocking CFM wait timed out
  ## (WifiCmdWaitTicks) because the RF/MAC was dead after a reconnect's
  ## bl_send_reset — re-initialise it so the NEXT reconnect attempt can queue
  ## commands again. Without this, every command after the first dead-RF timeout
  ## fast-fails -Epipe forever (enqueue.nim Crashed gate) and the device can only
  ## recover via a full reboot. Re-init is leak-free here (osMutexCreate is a
  ## stub returning a fixed handle). Returns true if a recovery re-init happened.
  if cmdMgr == nil: return false
  if loadU32(cmdMgr, MgrStateOff) != RwnxCmdMgrStateCrashed: return false
  bl_cmd_mgr_init(cmdMgr)
  inc nimFwDbgCmdMgrRecovered
  true
