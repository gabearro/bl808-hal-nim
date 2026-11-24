proc txCheckRet(isSta, isGroupcast: uint8; value: uint32): int =
  if (value and DescDoneSwTxBit) != 0:
    return 0
  # STA uplink uses the AP as the unicast receiver even for Ethernet groupcast.
  let successBit =
    if isSta == 0 and isGroupcast != 0: DescDoneTxBit
    else: FrameSuccessfulTxBit
  int((value and successBit) != 0)
