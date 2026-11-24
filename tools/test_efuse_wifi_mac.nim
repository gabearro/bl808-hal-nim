include ../src/bl808/efuse

let programmed = EfuseWifiMacShadow(low: 0x13579BDF'u32,
                                  highAndCheck: 0x06590224'u32)
let expected = [0x02'u8, 0x24'u8, 0x13'u8, 0x57'u8, 0x9B'u8, 0xDF'u8]
doAssert decodeEfuseWifiMac(programmed) == expected

var changed = programmed
changed.highAndCheck = changed.highAndCheck xor 0xFFC00000'u32
doAssert decodeEfuseWifiMac(changed) == expected

changed = programmed
changed.low = changed.low xor 1'u32
doAssert decodeEfuseWifiMac(changed) == default(array[6, uint8])
doAssert decodeEfuseWifiMac(default(EfuseWifiMacShadow)) == default(array[6, uint8])
