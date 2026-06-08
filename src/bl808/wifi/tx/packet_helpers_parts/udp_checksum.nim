proc checksumFold(acc0: uint32): uint16 {.inline.} =
  var acc = acc0
  while (acc shr 16) != 0'u32:
    acc = (acc and 0xffff'u32) + (acc shr 16)
  acc.uint16

proc checksumFinish(acc: uint32): uint16 {.inline.} =
  let folded = checksumFold(acc)
  let result = (not folded) and 0xffff'u16
  if result == 0'u16: 0xffff'u16 else: result

proc checksumAddBe16(acc: var uint32; raw: ptr UncheckedArray[uint8]; off: uint) {.inline.} =
  acc += loadBe16(raw, off).uint32

proc checksumUdpPacket(raw: ptr UncheckedArray[uint8]; ipOff, udpOff: uint;
                       udpLen: uint16; zeroChecksum: bool): uint16 =
  var acc = 0'u32
  checksumAddBe16(acc, raw, ipOff + 12'u)
  checksumAddBe16(acc, raw, ipOff + 14'u)
  checksumAddBe16(acc, raw, ipOff + 16'u)
  checksumAddBe16(acc, raw, ipOff + 18'u)
  acc += 17'u32
  acc += udpLen.uint32
  var i = 0'u
  while i + 1'u < udpLen.uint:
    let off = udpOff + i
    if zeroChecksum and i == 6'u:
      discard
    else:
      checksumAddBe16(acc, raw, off)
    i += 2'u
  if (udpLen and 1'u16) != 0'u16:
    acc += raw[udpOff + udpLen.uint - 1'u].uint32 shl 8
  checksumFinish(acc)

proc verifyUdpPacket(raw: ptr UncheckedArray[uint8]; ipOff, udpOff: uint;
                     udpLen: uint16): uint16 {.inline.} =
  checksumUdpPacket(raw, ipOff, udpOff, udpLen, false)
