when defined(bl808WifiNimDriverTrace):
  proc trace(msg: cstring) {.inline.} =
    c_printf("[WIFI-DRIVER] %s\r\n", msg)
else:
  template trace(msg: cstring) = discard

proc opPtr(operationSlotByteOffset: uint): pointer {.inline.} =
  cast[ptr pointer](cast[uint](addr g_bl_ops_funcs) + operationSlotByteOffset)[]

proc blOsTaskNotify(task: pointer) {.inline.} =
  let taskNotify = cast[TaskNotifyProc](opPtr(OpTaskNotifyOff))
  if taskNotify != nil:
    taskNotify(task)

proc blOsTaskGetCurrentTask(): pointer {.inline.} =
  let getCurrentTask = cast[TaskGetCurrentTaskProc](opPtr(OpTaskGetCurrentTaskOff))
  if getCurrentTask == nil: nil else: getCurrentTask()
