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

proc bl_utils_idx_lookup*(blHw: ptr BlHw; stationMacAddr: ptr uint8): cint {.exportc, cdecl.} =
  if blHw == nil or stationMacAddr == nil:
    return -1
  let remoteStaTable = ptrAt(cast[pointer](blHw), BlHwStaTableOff)
  for remoteStaIndex in 0 ..< NxRemoteStaStoreMax:
    let remoteStaEntry = ptrAt(remoteStaTable, uint(remoteStaIndex) * BlStaSize)
    if loadU8(remoteStaEntry, BlStaIsUsedOff) != 0'u8 and
        c_memcmp(ptrAt(remoteStaEntry, BlStaAddrOff), stationMacAddr, 6) == 0:
      return remoteStaIndex.cint
  -1
