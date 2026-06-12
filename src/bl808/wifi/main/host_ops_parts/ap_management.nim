proc bl_main_apm_start*(ssid, password: cstring; channel: cint; hiddenSsid: uint8;
                        bcnInt: uint16): cint {.exportc, cdecl.} =
  var cfm: array[SizeApmStartCfm, uint8]
  zero(addr cfm[0], cfm.len)
  let apVif = vifAt(BlVifAp)
  result = bl_send_apm_start_req(hwPtr(), cast[ptr ApmStartCfm](addr cfm[0]), ssid, password,
                                 channel, loadU8(apVif, BlVifVifIdxOff), hiddenSsid, bcnInt)
  let bcmcIdx = loadU8(addr cfm[0], ApmStartBcmcIdxOff)
  if bcmcIdx.uint < NxRemoteStaStoreMax:
    storeU8(apVif, BlVifFixedStaIdxOff, bcmcIdx)
    let sta = staAt(bcmcIdx.uint)
    storeU8(sta, BlStaVifIdxOff, BlVifAp.uint8)
    storeU8(sta, BlStaStaIdxOff, bcmcIdx)
    storeU8(sta, BlStaQosOff, 1'u8)

proc bl_main_apm_stop*(): cint {.exportc, cdecl.} =
  bl_send_apm_stop_req(hwPtr(), loadU8(vifAt(BlVifAp), BlVifVifIdxOff))

proc bl_main_apm_sta_cnt_get*(staCnt: ptr uint8): cint {.exportc, cdecl.} =
  if staCnt == nil:
    return -1
  staCnt[] = NxRemoteStaStoreMax.uint8
  0

proc bl_main_apm_sta_info_get*(apmStaInfo: pointer; idx: uint8): cint {.exportc, cdecl.} =
  if apmStaInfo == nil or idx.uint >= NxRemoteStaStoreMax:
    return -1
  let sta = staAt(idx.uint)
  if loadU8(sta, BlStaIsUsedOff) == 0'u8:
    return 0
  storeU8(apmStaInfo, ApmInfoStaIdxOff, loadU8(sta, BlStaStaIdxOff))
  storeU8(apmStaInfo, ApmInfoIsUsedOff, loadU8(sta, BlStaIsUsedOff))
  discard c_memcpy(ptrAt(apmStaInfo, ApmInfoStaMacOff), ptrAt(sta, BlStaAddrOff), 6)
  storeU32(apmStaInfo, ApmInfoTsfhiOff, loadU32(sta, BlStaTsfhiOff))
  storeU32(apmStaInfo, ApmInfoTsfloOff, loadU32(sta, BlStaTsfloOff))
  storeI32(apmStaInfo, ApmInfoRssiOff, loadI8(sta, BlStaRssiOff).int32)
  storeU8(apmStaInfo, ApmInfoRateOff, loadU8(sta, BlStaRateOff))
  0

proc bl_main_apm_sta_delete*(staIdx: uint8): cint {.exportc, cdecl.} =
  if staIdx.uint >= NxRemoteStaStoreMax:
    return -1
  let sta = staAt(staIdx.uint)
  let vifIdx = loadU8(sta, BlStaVifIdxOff)
  if vifIdx.uint >= NxVirtDevMax:
    return -1
  var cfm: array[SizeApmStaDelCfm, uint8]
  zero(addr cfm[0], cfm.len)
  discard bl_send_apm_sta_del_req(hwPtr(), cast[ptr ApmStaDelCfm](addr cfm[0]), staIdx,
                                  loadU8(vifAt(vifIdx.uint), BlVifVifIdxOff))
  if loadU8(addr cfm[0], ApmStaDelStatusOff) != 0'u8:
    return -1
  zero(sta, BlStaSize.int)
  0

proc bl_main_apm_remove_all_sta*(): cint {.exportc, cdecl.} =
  for remoteStaStoreIndex in 0'u ..< NxRemoteStaStoreMax:
    if loadU8(staAt(remoteStaStoreIndex), BlStaIsUsedOff) == 1'u8:
      discard bl_main_apm_sta_delete(remoteStaStoreIndex.uint8)
  0

proc bl_main_conf_max_sta*(maxStaSupported: uint8): cint {.exportc, cdecl.} =
  bl_send_apm_conf_max_sta_req(hwPtr(), maxStaSupported)
