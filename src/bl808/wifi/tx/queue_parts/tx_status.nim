proc txCheckRet(isSta, isGroupcast: uint8; value: uint32): int =
  discard isSta
  if (isGroupcast == 0'u8 and (value and FrameSuccessfulTxBit) != 0'u32) or
      (isGroupcast != 0'u8 and (value and DescDoneTxBit) != 0'u32):
    return 1
  0
