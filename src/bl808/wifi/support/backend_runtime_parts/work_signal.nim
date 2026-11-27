## A scheduler callback is optional: bare-loop images never install one.
## The hook is a plain function pointer, so signaling from a trap does not
## allocate or touch a CPS future in interrupt context.

proc vendorNotifyWork() =
  let hook = wifiSchedulerWorkHook
  if hook != nil:
    hook()

proc bl808_wifi_backend_set_work_hook*(hook: proc() {.cdecl.})
    {.exportc, cdecl.} =
  let saved = osEnterCritical()
  wifiSchedulerWorkHook = hook
  osExitCritical(saved)

proc bl808_wifi_backend_signal_work*() {.exportc, cdecl.} =
  vendorNotifyWork()
