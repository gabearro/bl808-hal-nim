proc bl_radarind*(pthis, hostid: pointer): uint8 {.exportc, cdecl.} =
  discard pthis
  discard hostid
  0

proc bl_msgackind*(pthis, hostid: pointer): uint8 {.exportc, cdecl.} =
  if pthis != nil:
    let llind = cast[CmdLlindProc](loadPtr(pthis, BlCmdMgrLlindOff))
    if llind != nil:
      discard llind(pthis, hostid)
  0

proc bl_dbgind*(pthis, hostid: pointer): uint8 {.exportc, cdecl.} =
  discard pthis
  discard hostid
  0

proc bl_prim_tbtt_ind*(pthis: pointer) {.exportc, cdecl.} =
  discard pthis

proc bl_sec_tbtt_ind*(pthis: pointer) {.exportc, cdecl.} =
  discard pthis

proc bl_utils_idx_lookup*(blHw: ptr BlHw; mac: ptr uint8): cint {.exportc, cdecl.} =
  if blHw == nil or mac == nil:
    return -1
  let staTable = ptrAt(cast[pointer](blHw), BlHwStaTableOff)
  for i in 0 ..< NxRemoteStaStoreMax:
    let sta = ptrAt(staTable, uint(i) * BlStaSize)
    if loadU8(sta, BlStaIsUsedOff) != 0'u8 and
        c_memcmp(ptrAt(sta, BlStaAddrOff), mac, 6) == 0:
      return i.cint
  -1
