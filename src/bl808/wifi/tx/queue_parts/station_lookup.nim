proc txCntrlGetStaId(isSta: int; isBroadcast: bool; macAddr: pointer): int =
  inc nimFwDbgTxStaLookup
  nimFwDbgTxStaLookupMode = isSta.uint32 or
    (if isBroadcast: 0x100'u32 else: 0'u32)
  if isSta != 0:
    let vif = vifView(vifAt(BlVifSta))
    let apIdx = vif.fixedStaIdx
    nimFwDbgTxStaLookupVif = vif.linksNum.uint32 or
      (apIdx.uint32 shl 8) or
      (vif.fcChan.uint32 shl 16) or
      (vif.vifIdx.uint32 shl 24)
    if apIdx >= NxRemoteStaStoreMax.uint8:
      inc nimFwDbgTxStaLookupFail
      nimFwDbgTxStaLookupSta = 0x80000000'u32 or apIdx.uint32
      nimFwDbgTxStaLookupResult = 0xffffffff'u32
      return -1
    let sta = staView(staAt(apIdx.int))
    nimFwDbgTxStaLookupSta = sta.isUsed.uint32 or
      (sta.staIdx.uint32 shl 8) or
      (sta.vifIdx.uint32 shl 16) or
      (sta.qos.uint32 shl 24)
    if vif.linksNum != 0'u8 and sta.isUsed != 0'u8:
      nimFwDbgTxStaLookupResult = sta.staIdx.uint32
      return sta.staIdx.int
    inc nimFwDbgTxStaLookupFail
    nimFwDbgTxStaLookupResult = 0xffffffff'u32
    return -1

  let apVif = vifView(vifAt(BlVifAp))
  if apVif.linksNum == 0'u8:
    inc nimFwDbgTxStaLookupFail
    nimFwDbgTxStaLookupVif = apVif.linksNum.uint32 or
      (apVif.fixedStaIdx.uint32 shl 8) or
      (apVif.fcChan.uint32 shl 16) or
      (apVif.vifIdx.uint32 shl 24)
    nimFwDbgTxStaLookupResult = 0xffffffff'u32
    return -1

  let bcmcStaIdx = apVif.fixedStaIdx.int
  if isBroadcast:
    let sta = staView(staAt(bcmcStaIdx))
    nimFwDbgTxStaLookupSta = sta.isUsed.uint32 or
      (sta.staIdx.uint32 shl 8) or
      (sta.vifIdx.uint32 shl 16) or
      (sta.qos.uint32 shl 24)
    if sta.isUsed != 0'u8:
      nimFwDbgTxStaLookupResult = sta.staIdx.uint32
      return sta.staIdx.int
    inc nimFwDbgTxStaLookupFail
    nimFwDbgTxStaLookupResult = 0xffffffff'u32
    return -1

  for i in 0 ..< NxRemoteStaStoreMax:
    if i == bcmcStaIdx:
      continue
    let sta = staView(staAt(i))
    if sta.isUsed != 0'u8 and
        c_memcmp(cast[pointer](addr sta.macAddr[0]), macAddr, EthAlen.csize_t) == 0:
      nimFwDbgTxStaLookupResult = i.uint32
      return i
  inc nimFwDbgTxStaLookupFail
  nimFwDbgTxStaLookupResult = 0xffffffff'u32
  -1
