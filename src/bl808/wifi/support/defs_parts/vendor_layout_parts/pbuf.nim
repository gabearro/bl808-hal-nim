const
  PbufSize = 16'u
  PbufNextOff = 0'u
  PbufPayloadOff = 4'u
  PbufTotLenOff = 8'u
  PbufLenOff = 10'u
  PbufFlagsOff = 13'u
  PbufRefOff = 14'u
  PbufCustomFreeOff = 16'u
  PbufFlagIsCustom = 0x02'u8
  PbufDefaultHeadroom = 64'u
