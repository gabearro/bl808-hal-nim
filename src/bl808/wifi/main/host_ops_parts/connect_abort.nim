proc bl_main_connect_abort*(status: ptr uint8): cint {.exportc, cdecl.} =
  if status == nil:
    return -1
  var cfm: array[SizeSmAbortCfm, uint8]
  zero(addr cfm[0], cfm.len)
  discard bl_send_sm_connect_abort_req(hwPtr(), cast[ptr SmAbortCfm](addr cfm[0]))
  status[] = loadU8(addr cfm[0], SmAbortStatusOff)
  0
