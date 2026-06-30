proc checksumFold(acc0: uint32): uint16 {.inline.} =
  var acc = acc0
  while (acc shr 16) != 0'u32:
    acc = (acc and 0xffff'u32) + (acc shr 16)
  acc.uint16

proc checksumFinish(acc: uint32): uint16 {.inline.} =
  let folded = checksumFold(acc)
  let result = (not folded) and 0xffff'u16
  if result == 0'u16: 0xffff'u16 else: result

proc checksumAddBe16(acc: var uint32; packetBytes: ptr UncheckedArray[uint8];
                     byteOffset: uint) {.inline.} =
  acc += loadBe16(packetBytes, byteOffset).uint32

proc checksumUdpPacket(packetBytes: ptr UncheckedArray[uint8];
                       ipHeaderOffset, udpHeaderOffset: uint;
                       udpLen: uint16; zeroChecksum: bool): uint16 =
  var acc = 0'u32
  checksumAddBe16(acc, packetBytes, ipHeaderOffset + 12'u)
  checksumAddBe16(acc, packetBytes, ipHeaderOffset + 14'u)
  checksumAddBe16(acc, packetBytes, ipHeaderOffset + 16'u)
  checksumAddBe16(acc, packetBytes, ipHeaderOffset + 18'u)
  acc += 17'u32
  acc += udpLen.uint32
  var udpSegmentOffset = 0'u
  while udpSegmentOffset + 1'u < udpLen.uint:
    let checksumWordOffset = udpHeaderOffset + udpSegmentOffset
    if zeroChecksum and udpSegmentOffset == 6'u:
      discard
    else:
      checksumAddBe16(acc, packetBytes, checksumWordOffset)
    udpSegmentOffset += 2'u
  if (udpLen and 1'u16) != 0'u16:
    acc += packetBytes[udpHeaderOffset + udpLen.uint - 1'u].uint32 shl 8
  checksumFinish(acc)

proc verifyUdpPacket(packetBytes: ptr UncheckedArray[uint8];
                     ipHeaderOffset, udpHeaderOffset: uint;
                     udpLen: uint16): uint16 {.inline.} =
  checksumUdpPacket(packetBytes, ipHeaderOffset, udpHeaderOffset, udpLen, false)

proc checksumTcpPacket(packetBytes: ptr UncheckedArray[uint8];
                       ipHeaderOffset, tcpHeaderOffset: uint;
                       tcpLen: uint16; zeroChecksum: bool): uint16 =
  var acc = 0'u32
  checksumAddBe16(acc, packetBytes, ipHeaderOffset + 12'u)
  checksumAddBe16(acc, packetBytes, ipHeaderOffset + 14'u)
  checksumAddBe16(acc, packetBytes, ipHeaderOffset + 16'u)
  checksumAddBe16(acc, packetBytes, ipHeaderOffset + 18'u)
  acc += 6'u32
  acc += tcpLen.uint32
  var tcpSegmentOffset = 0'u
  while tcpSegmentOffset + 1'u < tcpLen.uint:
    let checksumWordOffset = tcpHeaderOffset + tcpSegmentOffset
    if zeroChecksum and tcpSegmentOffset == 16'u:
      discard
    else:
      checksumAddBe16(acc, packetBytes, checksumWordOffset)
    tcpSegmentOffset += 2'u
  if (tcpLen and 1'u16) != 0'u16:
    acc += packetBytes[tcpHeaderOffset + tcpLen.uint - 1'u].uint32 shl 8
  checksumFinish(acc)

proc verifyTcpPacket(packetBytes: ptr UncheckedArray[uint8];
                     ipHeaderOffset, tcpHeaderOffset: uint;
                     tcpLen: uint16): uint16 {.inline.} =
  checksumTcpPacket(packetBytes, ipHeaderOffset, tcpHeaderOffset, tcpLen, false)
