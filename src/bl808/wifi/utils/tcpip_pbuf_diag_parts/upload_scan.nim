## Scan uploaded frames for TCP/UDP packets useful to hardware probes.

proc macDataHeaderLen(fc: uint16): uint32 {.inline.} =
  result = 24'u32
  if (fc and 0x0300'u16) == 0x0300'u16:
    result += 6
  if (fc and 0x0080'u16) != 0:
    result += 2
  if (fc and 0x4000'u16) != 0:
    result += 8

proc noteUploadScan(pkt: pointer; msduOffset, flags: uint32) =
  if pkt == nil:
    return
  let firstLen = loadU16(pkt, WifiPktLenOff).uint32
  if firstLen < 24'u32:
    return
  let raw = cast[pointer](loadU32(pkt, WifiPktPktOff).uint)
  var off = 0'u32
  while off + 28'u32 <= firstLen and off < 128'u32:
    let vihl = loadU8(raw, off.uint)
    if (vihl and 0xF0'u8) == 0x40'u8:
      let ihl = ((vihl and 0x0F'u8).uint32) * 4'u32
      let proto = loadU8(raw, off.uint + 9'u).uint32
      let totalLen = loadBe16(raw, off.uint + 2'u).uint32
      if ihl >= 20'u32 and totalLen >= ihl and off + ihl + 4'u32 <= firstLen:
        let l4 = off + ihl
        let srcPort = loadBe16(raw, l4.uint)
        let dstPort = loadBe16(raw, l4.uint + 2'u)
        let interesting =
          (proto == 6'u32 and (srcPort == 80'u16 or dstPort == 80'u16)) or
          (proto == 17'u32 and (srcPort == 65000'u16 or dstPort == 65000'u16))
        if interesting:
          inc nimFwDbgTcpipInputScanHit
          nimFwDbgTcpipInputScanMeta =
            off or (ihl shl 8) or (proto shl 16) or
            ((msduOffset and 0xFF'u32) shl 24)
          nimFwDbgTcpipInputScanPorts =
            srcPort.uint32 or (dstPort.uint32 shl 16)
          for i in 0 ..< nimFwDbgTcpipInputScanRaw.len:
            let src = off + i.uint32
            nimFwDbgTcpipInputScanRaw[i] =
              if src < firstLen: loadU8(raw, src.uint) else: 0'u8
          return
    inc off

proc validEthernetAt(raw: pointer; firstLen, off: uint32): bool =
  if off + 14'u32 > firstLen:
    return false
  let etherType = loadBe16(raw, off.uint + 12'u)
  if etherType == 0x0806'u16:
    return off + 42'u32 <= firstLen and
      loadBe16(raw, off.uint + 14'u) == 1'u16 and
      loadBe16(raw, off.uint + 16'u) == 0x0800'u16
  if etherType == 0x0800'u16:
    if off + 34'u32 > firstLen:
      return false
    let ip = off + 14'u32
    let vihl = loadU8(raw, ip.uint)
    let ihl = ((vihl and 0x0F'u8).uint32) * 4'u32
    let totalLen = loadBe16(raw, ip.uint + 2'u).uint32
    return (vihl and 0xF0'u8) == 0x40'u8 and ihl >= 20'u32 and
      totalLen >= ihl and ip + totalLen <= firstLen
  false

proc ethernetOffsetForUpload(pkt: pointer; defaultOffset: uint32): uint32 =
  result = defaultOffset
  if pkt == nil:
    return
  let firstLen = loadU16(pkt, WifiPktLenOff).uint32
  if firstLen < 14'u32:
    return
  let raw = cast[pointer](loadU32(pkt, WifiPktPktOff).uint)
  if validEthernetAt(raw, firstLen, defaultOffset):
    return
  var off = 0'u32
  while off + 14'u32 <= firstLen and off < 128'u32:
    if validEthernetAt(raw, firstLen, off):
      return off
    inc off
