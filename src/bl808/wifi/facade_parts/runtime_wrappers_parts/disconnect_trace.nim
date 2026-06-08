when defined(bl808WifiNimFwDiag):
  proc dcTrace(s: cstring) {.importc: "cfg_trace", cdecl.}
  proc dcTraceRc(s: cstring; v: cint) {.importc: "cfg_trace_rc", cdecl.}

proc wifiDisconnectTrace(message: cstring) {.inline.} =
  when defined(bl808WifiNimFwDiag):
    dcTrace(message)
  else:
    discard message

proc wifiDisconnectTraceRc(message: cstring; value: cint) {.inline.} =
  when defined(bl808WifiNimFwDiag):
    dcTraceRc(message, value)
  else:
    discard message
    discard value
