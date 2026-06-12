proc bl_get_fixed_channels_is_valid*(channels: ptr uint16; channelNum: uint16): cint
    {.exportc, cdecl.} =
  if channelNum == 0:
    return 0
  for fixedChannelIndex in 0 ..< channelNum.int:
    let channel = cast[ptr UncheckedArray[uint16]](channels)[fixedChannelIndex]
    if channel == 0'u16 or channel > channelNumDefault.uint16:
      return 0
  1
