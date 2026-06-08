type
  SendDataCfm = proc(pthis, hostId: pointer): cint {.cdecl.}
  RecvInd = proc(pthis, hostId: pointer): uint8 {.cdecl.}
  TbttInd = proc(pthis: pointer) {.cdecl.}
