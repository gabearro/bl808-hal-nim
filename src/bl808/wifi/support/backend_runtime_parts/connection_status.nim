proc bl808_wifi_backend_connected*(): cint {.exportc, cdecl.} =
  if connectDone == 0: 1 else: 0

proc bl808_wifi_backend_connect_done*(): cint {.exportc, cdecl.} =
  if connectDone >= 0: 1 else: 0

proc bl808_wifi_backend_disconnect_done*(): cint {.exportc, cdecl.} =
  if disconnectDone != 0: 1 else: 0

proc bl808_wifi_backend_last_status*(): cint {.exportc, cdecl.} =
  lastStatusCode.cint

proc bl808_wifi_backend_last_reason*(): cint {.exportc, cdecl.} =
  lastReasonCode.cint
