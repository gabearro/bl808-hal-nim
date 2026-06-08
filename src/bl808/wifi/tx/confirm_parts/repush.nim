proc repushTxConfirmIfNeeded(txhdr, sta: pointer; staO: ptr BlStaView; linksNum: uint8;
                             ret: int; value: uint32): bool =
  if ret != 0 or txHdrRepush(txhdr) >= 3'u8 or linksNum == 0'u8 or staO.isUsed == 0'u8:
    return false

  if (value and RetryLimitReachedBit) != 0'u32:
    txCntrlStaTriggerPending = txCntrlStaTriggerPending or bitSta(staO.staIdx)
  elif (value and FrameRepushableChanBit) != 0'u32:
    vifView(staVif(sta)).fcChan = 1
  elif (value and FrameRepushablePsBit) != 0'u32:
    staO.fcPs = 1
  else:
    discard

  if (value and (RetryLimitReachedBit or FrameRepushableChanBit or FrameRepushablePsBit)) == 0'u32:
    return false

  setTxHdrRepush(txhdr, txHdrRepush(txhdr) + 1'u8)
  listPushBack(cast[pointer](addr staO.pendingList), txhdr)
  true
