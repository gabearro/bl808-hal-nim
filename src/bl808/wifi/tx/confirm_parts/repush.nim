proc repushTxConfirmIfNeeded(txHeaderPtr, station: pointer; stationState: ptr BlStaView; stationLinkCount: uint8;
                             txConfirmResult: int; txStatusWord: uint32): bool =
  if txConfirmResult != 0 or txHdrRepush(txHeaderPtr) >= 3'u8 or stationLinkCount == 0'u8 or stationState.isUsed == 0'u8:
    return false

  if (txStatusWord and RetryLimitReachedBit) != 0'u32:
    txCntrlStaTriggerPending = txCntrlStaTriggerPending or bitSta(stationState.staIdx)
  elif (txStatusWord and FrameRepushableChanBit) != 0'u32:
    vifView(staVif(station)).fcChan = 1
  elif (txStatusWord and FrameRepushablePsBit) != 0'u32:
    stationState.fcPs = 1
  else:
    discard

  if (txStatusWord and (RetryLimitReachedBit or FrameRepushableChanBit or FrameRepushablePsBit)) == 0'u32:
    return false

  setTxHdrRepush(txHeaderPtr, txHdrRepush(txHeaderPtr) + 1'u8)
  listPushBack(cast[pointer](addr stationState.pendingList), txHeaderPtr)
  true
