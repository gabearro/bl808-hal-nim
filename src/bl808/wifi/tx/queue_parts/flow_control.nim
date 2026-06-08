proc bitSta(idx: uint8): uint32 {.inline.} =
  1'u32 shl idx

proc bitSta(idx: int): uint32 {.inline.} =
  1'u32 shl idx

proc bitVif(idx: int): uint8 {.inline.} =
  1'u8 shl idx

proc isBcMc(firstByte: uint8): bool {.inline.} =
  (firstByte and 1'u8) != 0'u8

proc txCntrlCheckFc(sta: pointer): bool =
  staView(sta).fcPs == 0'u8 and vifView(staVif(sta)).fcChan == 0'u8

proc txCntrlUpdateFc(txFcField: pointer): uint32 =
  let fc = keTxFcView(txFcField)
  for i in 0 ..< 2:
    if (fc.vifBits and bitVif(i)) != 0'u8:
      if i == BlVifSta:
        let vif = vifView(vifAt(BlVifSta))
        let fixedStaIdx = vif.fixedStaIdx
        if fc.staFcChan != 0'u8:
          vif.fcChan = 0
        if fc.staFcPs != 0'u8:
          staView(staAt(fixedStaIdx.int)).fcPs = 0
        result = result or bitSta(fixedStaIdx)
      else:
        let vif = vifView(vifAt(BlVifAp))
        let fixedStaIdx = vif.fixedStaIdx
        if fc.apFcChan != 0'u8:
          vif.fcChan = 0
          result = result or bitSta(fixedStaIdx)
        result = result or fc.apFcPsStaBits.uint32
