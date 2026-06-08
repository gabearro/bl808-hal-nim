when defined(bl808WifiNimDriverTrace):
  proc trace(msg: cstring) {.inline.} =
    c_printf("[WIFI-DRIVER] %s\r\n", msg)
else:
  template trace(msg: cstring) = discard

proc opPtr(off: uint): pointer {.inline.} =
  cast[ptr pointer](cast[uint](addr g_bl_ops_funcs) + off)[]

proc blOsTaskNotify(task: pointer) {.inline.} =
  let fn = cast[TaskNotifyProc](opPtr(OpTaskNotifyOff))
  if fn != nil:
    fn(task)

proc blOsTaskGetCurrentTask(): pointer {.inline.} =
  let fn = cast[TaskGetCurrentTaskProc](opPtr(OpTaskGetCurrentTaskOff))
  if fn == nil: nil else: fn()
