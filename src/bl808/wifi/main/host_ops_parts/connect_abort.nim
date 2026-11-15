proc bl_main_connect_abort*(status: ptr uint8): cint {.exportc, cdecl.} =
  if status == nil:
    return -1
  var cfm: array[SizeSmAbortCfm, uint8]
  zero(addr cfm[0], cfm.len)
  result = bl_send_sm_connect_abort_req(hwPtr(), cast[ptr SmAbortCfm](addr cfm[0]))
  if result != 0:
    return
  status[] = loadU8(addr cfm[0], SmAbortStatusOff)
