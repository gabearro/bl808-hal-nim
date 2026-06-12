proc nimFwDbgDhcpTxFinalBreakpoint*() {.exportc: "nimfw_dbg_dhcp_tx_final_breakpoint",
    cdecl, noinline.} =
  inc nimFwDbgDhcpTxFinalBreakHits

proc nimFwDbgRxuDupDropBreakpoint*() {.exportc: "nimfw_dbg_rxu_dup_drop_breakpoint",
    cdecl, noinline.} =
  inc nimFwDbgRxuDupBreakHits

proc nimFwDbgRxuIpv4Preupload(frame: ptr MacDataFrameHeaderView;
                              machdrLen, tid: uint8;
                              frameLen: uint16) {.noinline.} =
  if frameLen.uint32 < machdrLen.uint32 + sizeof(LlcSnapHeaderView).uint32 + 20'u32:
    return
  let msduView = rxMsduView(frame, machdrLen)
  let msdu = addr msduView.snap
  if not rxSnapIsRfc1042(msdu) or msdu.ethertype != 0x0008'u16:
    return
  let msduLen = frameLen.uint32 - machdrLen.uint32
  let ipPayload = cast[ptr UncheckedArray[uint8]](rxMsduPayload(msduView))
  let version = ipPayload[0] shr 4
  let ihl = (ipPayload[0].uint32 and 0x0F'u32) shl 2
  if version != 4'u8 or ihl < 20'u32 or
      msduLen < sizeof(LlcSnapHeaderView).uint32 + ihl:
    return
  let proto = ipPayload[9].uint32
  nimFwDbgRxuAssocLastIpProto = proto or
    (frameLen.uint32 shl 8) or (machdrLen.uint32 shl 24)
  if proto == 17'u32:
    inc nimFwDbgRxuAssocUdp
  elif proto == 6'u32 and
      msduLen >= sizeof(LlcSnapHeaderView).uint32 + ihl + 20'u32:
    inc nimFwDbgRxuAssocTcp
    let tcp = cast[ptr UncheckedArray[uint8]](
      cast[pointer](cast[uint](ipPayload) + ihl.uint))
    let srcPort = (tcp[0].uint32 shl 8) or tcp[1].uint32
    let dstPort = (tcp[2].uint32 shl 8) or tcp[3].uint32
    let flags = tcp[13].uint32
    nimFwDbgRxuAssocLastTcpPorts = (srcPort shl 16) or dstPort
    nimFwDbgRxuAssocLastTcpFlags = flags
    if srcPort == 80'u32 or dstPort == 80'u32:
      inc nimFwDbgRxuAssocTcp80
      nimFwDbgRxuAssocTcpMeta = frameLen.uint32 or
        (machdrLen.uint32 shl 16) or (tid.uint32 shl 24)
      let copyLen =
        if msduLen - sizeof(LlcSnapHeaderView).uint32 < 64'u32:
          msduLen - sizeof(LlcSnapHeaderView).uint32
        else:
          64'u32
      for tcpRawClearByteIndex in 0 ..< 64:
        nimFwDbgRxuAssocTcpRaw[tcpRawClearByteIndex] = 0
      for tcpRawCopyByteIndex in 0'u32 ..< copyLen:
        nimFwDbgRxuAssocTcpRaw[tcpRawCopyByteIndex.int] = ipPayload[tcpRawCopyByteIndex]

proc nimFwDbgRxuDhcpMsg(frame: ptr MacDataFrameHeaderView; machdrLen: uint8;
                        frameLen: uint16): uint32 {.noinline.} =
  if frameLen.uint32 < machdrLen.uint32 + sizeof(LlcSnapHeaderView).uint32:
    return 0
  let msduView = rxMsduView(frame, machdrLen)
  let msdu = addr msduView.snap
  let msduLen = frameLen.uint32 - machdrLen.uint32
  let ipPayload = cast[ptr UncheckedArray[uint8]](rxMsduPayload(msduView))
  if not rxSnapIsRfc1042(msdu) or msdu.ethertype != 0x0008'u16 or
      msduLen < 28'u32:
    return 0
  let ihl = (ipPayload[0].uint32 and 0x0F'u32) shl 2
  if ihl < 20'u32 or msduLen < sizeof(LlcSnapHeaderView).uint32 + ihl + 8'u32:
    return 0
  let udp = cast[pointer](cast[uint](ipPayload) + ihl.uint)
  if debugLoadLe32(udp) != 0x44004300'u32:
    return 0
  if msduLen < sizeof(LlcSnapHeaderView).uint32 + ihl + 8'u32 + 240'u32:
    return 0
  let bootp = cast[pointer](cast[uint](udp) + 8'u)
  var optOff = cast[uint](bootp) + 240'u
  let optEnd = cast[uint](ipPayload) + msduLen.uint
  var guard = 0
  while optOff < optEnd and guard < 64:
    inc guard
    let code = cast[ptr uint8](optOff)[]
    inc optOff
    if code == 0'u8:
      continue
    if code == 255'u8 or optOff >= optEnd:
      break
    let optLen = cast[ptr uint8](optOff)[]
    inc optOff
    if optOff + optLen.uint > optEnd:
      break
    if code == 53'u8 and optLen >= 1'u8:
      return cast[ptr uint8](optOff)[].uint32
    optOff += optLen.uint
  0

proc nimFwDbgRecordRxuDupDrop(frame: ptr MacDataFrameHeaderView; hwFlags: uint32;
                              envSeq: uint16; tid, machdrLen: uint8;
                              cachedSeq: uint16; frameLen: uint16) {.noinline.} =
  let dupTraceSlot = int(nimFwDbgRxuDupTraceCount mod RxuDupTraceEntries.uint32)
  inc nimFwDbgRxuDupTraceCount
  let msduView = rxMsduView(frame, machdrLen)
  let msdu = addr msduView.snap
  nimFwDbgRxuDupTraceFc[dupTraceSlot] = frame.frameControl.uint32 or
    (hwFlags and 0xFFFF0000'u32)
  nimFwDbgRxuDupTraceSeq[dupTraceSlot] = envSeq.uint32 or
    (tid.uint32 shl 16) or (machdrLen.uint32 shl 24)
  nimFwDbgRxuDupTraceCache[dupTraceSlot] = cachedSeq.uint32
  nimFwDbgRxuDupTraceSnapLo[dupTraceSlot] = rxSnapTraceLo(msdu)
  nimFwDbgRxuDupTraceSnapHi[dupTraceSlot] = rxSnapTraceHi(msdu)
  nimFwDbgRxuDupTraceAddr0[dupTraceSlot] = debugLoadLe32(addr frame.addr1[0])
  nimFwDbgRxuDupTraceAddr1[dupTraceSlot] = debugLoadLe32(addr frame.addr2[0])
  nimFwDbgRxuDupTraceIp0[dupTraceSlot] = 0
  nimFwDbgRxuDupTraceUdp0[dupTraceSlot] = 0
  nimFwDbgRxuDupTraceBootp0[dupTraceSlot] = 0
  nimFwDbgRxuDupTraceBootp1[dupTraceSlot] = 0
  nimFwDbgRxuDupTraceBootpYiaddr[dupTraceSlot] = 0
  nimFwDbgRxuDupTraceDhcpMsg[dupTraceSlot] = 0
  nimFwDbgRxuDupTraceDhcpServer[dupTraceSlot] = 0
  if frameLen.uint32 >= machdrLen.uint32 + sizeof(LlcSnapHeaderView).uint32:
    let msduLen = frameLen.uint32 - machdrLen.uint32
    let ipPayload = cast[ptr UncheckedArray[uint8]](rxMsduPayload(msduView))
    if rxSnapIsRfc1042(msdu) and msdu.ethertype == 0x0008'u16 and msduLen >= 28'u32:
      nimFwDbgRxuDupTraceIp0[dupTraceSlot] = debugLoadLe32(cast[pointer](ipPayload))
      let ihl = (ipPayload[0].uint32 and 0x0F'u32) shl 2
      if ihl >= 20'u32 and msduLen >= sizeof(LlcSnapHeaderView).uint32 + ihl + 8'u32:
        let udp = cast[pointer](cast[uint](ipPayload) + ihl.uint)
        nimFwDbgRxuDupTraceUdp0[dupTraceSlot] = debugLoadLe32(udp)
        if msduLen >= sizeof(LlcSnapHeaderView).uint32 + ihl + 16'u32:
          let bootp = cast[pointer](cast[uint](udp) + 8'u)
          nimFwDbgRxuDupTraceBootp0[dupTraceSlot] = debugLoadLe32(bootp)
          nimFwDbgRxuDupTraceBootp1[dupTraceSlot] =
            debugLoadLe32(cast[pointer](cast[uint](udp) + 12'u))
          if msduLen >= sizeof(LlcSnapHeaderView).uint32 + ihl + 32'u32:
            nimFwDbgRxuDupTraceBootpYiaddr[dupTraceSlot] =
              debugLoadLe32(cast[pointer](cast[uint](bootp) + 16'u))
          if msduLen >= sizeof(LlcSnapHeaderView).uint32 + ihl + 8'u32 + 240'u32:
            var optOff = cast[uint](bootp) + 240'u
            let optEnd = cast[uint](ipPayload) + msduLen.uint
            var guard = 0
            while optOff < optEnd and guard < 64:
              inc guard
              let code = cast[ptr uint8](optOff)[]
              inc optOff
              if code == 0'u8:
                continue
              if code == 255'u8 or optOff >= optEnd:
                break
              let optLen = cast[ptr uint8](optOff)[]
              inc optOff
              if optOff + optLen.uint > optEnd:
                break
              if code == 53'u8 and optLen >= 1'u8:
                nimFwDbgRxuDupTraceDhcpMsg[dupTraceSlot] =
                  cast[ptr uint8](optOff)[].uint32
              elif code == 54'u8 and optLen >= 4'u8:
                nimFwDbgRxuDupTraceDhcpServer[dupTraceSlot] =
                  debugLoadLe32(cast[pointer](optOff))
              optOff += optLen.uint
  nimFwDbgRxuDupDropBreakpoint()

proc nimFwDbgRecordRxuPnDrop(frame: ptr MacDataFrameHeaderView; hwFlags: uint32;
                             envSeq: uint16; tid, machdrLen: uint8;
                             frameLen: uint16) {.noinline.} =
  let pnDropTraceSlot = int(nimFwDbgRxuPnDropTraceCount mod RxuPnDropTraceEntries.uint32)
  inc nimFwDbgRxuPnDropTraceCount
  let env = rxuCntrlEnvView()
  let msduView = rxMsduView(frame, machdrLen)
  let msdu = addr msduView.snap
  nimFwDbgRxuPnDropTraceFc[pnDropTraceSlot] = frame.frameControl.uint32 or
    (hwFlags and 0xFFFF0000'u32)
  nimFwDbgRxuPnDropTraceSeq[pnDropTraceSlot] = envSeq.uint32 or
    (tid.uint32 shl 16) or (machdrLen.uint32 shl 24)
  nimFwDbgRxuPnDropTracePnLo[pnDropTraceSlot] = env.secInfo0
  nimFwDbgRxuPnDropTracePnHi[pnDropTraceSlot] = env.secInfo1
  nimFwDbgRxuPnDropTraceStoredLo[pnDropTraceSlot] = nimFwDbgRxuPnStoredLo
  nimFwDbgRxuPnDropTraceStoredHi[pnDropTraceSlot] = nimFwDbgRxuPnStoredHi
  nimFwDbgRxuPnDropTraceSnapLo[pnDropTraceSlot] = rxSnapTraceLo(msdu)
  nimFwDbgRxuPnDropTraceSnapHi[pnDropTraceSlot] = rxSnapTraceHi(msdu)
  nimFwDbgRxuPnDropTraceUdp0[pnDropTraceSlot] = 0
  nimFwDbgRxuPnDropTraceBootpYiaddr[pnDropTraceSlot] = 0
  nimFwDbgRxuPnDropTraceDhcpMsg[pnDropTraceSlot] = 0
  nimFwDbgRxuPnDropTraceDhcpServer[pnDropTraceSlot] = 0
  if frameLen.uint32 >= machdrLen.uint32 + sizeof(LlcSnapHeaderView).uint32:
    let msduLen = frameLen.uint32 - machdrLen.uint32
    let ipPayload = cast[ptr UncheckedArray[uint8]](rxMsduPayload(msduView))
    if rxSnapIsRfc1042(msdu) and msdu.ethertype == 0x0008'u16 and msduLen >= 28'u32:
      let ihl = (ipPayload[0].uint32 and 0x0F'u32) shl 2
      if ihl >= 20'u32 and msduLen >= sizeof(LlcSnapHeaderView).uint32 + ihl + 8'u32:
        let udp = cast[pointer](cast[uint](ipPayload) + ihl.uint)
        nimFwDbgRxuPnDropTraceUdp0[pnDropTraceSlot] = debugLoadLe32(udp)
        if msduLen >= sizeof(LlcSnapHeaderView).uint32 + ihl + 32'u32:
          let bootp = cast[pointer](cast[uint](udp) + 8'u)
          nimFwDbgRxuPnDropTraceBootpYiaddr[pnDropTraceSlot] =
            debugLoadLe32(cast[pointer](cast[uint](bootp) + 16'u))
          if msduLen >= sizeof(LlcSnapHeaderView).uint32 + ihl + 8'u32 + 240'u32:
            var optOff = cast[uint](bootp) + 240'u
            let optEnd = cast[uint](ipPayload) + msduLen.uint
            var guard = 0
            while optOff < optEnd and guard < 64:
              inc guard
              let code = cast[ptr uint8](optOff)[]
              inc optOff
              if code == 0'u8:
                continue
              if code == 255'u8 or optOff >= optEnd:
                break
              let optLen = cast[ptr uint8](optOff)[]
              inc optOff
              if optOff + optLen.uint > optEnd:
                break
              if code == 53'u8 and optLen >= 1'u8:
                nimFwDbgRxuPnDropTraceDhcpMsg[pnDropTraceSlot] =
                  cast[ptr uint8](optOff)[].uint32
              elif code == 54'u8 and optLen >= 4'u8:
                nimFwDbgRxuPnDropTraceDhcpServer[pnDropTraceSlot] =
                  debugLoadLe32(cast[pointer](optOff))
              optOff += optLen.uint

proc nimFwDbgRecordRxuPnAccept(stage: uint32; frame: ptr MacDataFrameHeaderView;
                               hwFlags: uint32; envSeq: uint16;
                               tid, machdrLen: uint8; frameLen: uint16) {.noinline.} =
  let pnAcceptTraceSlot = int(nimFwDbgRxuPnAcceptTraceCount mod RxuPnAcceptTraceEntries.uint32)
  inc nimFwDbgRxuPnAcceptTraceCount
  let env = rxuCntrlEnvView()
  let msduView = rxMsduView(frame, machdrLen)
  let msdu = addr msduView.snap
  nimFwDbgRxuPnAcceptTraceStage[pnAcceptTraceSlot] = stage
  nimFwDbgRxuPnAcceptTraceFc[pnAcceptTraceSlot] = frame.frameControl.uint32 or
    (hwFlags and 0xFFFF0000'u32)
  nimFwDbgRxuPnAcceptTraceSeq[pnAcceptTraceSlot] = envSeq.uint32 or
    (tid.uint32 shl 16) or (machdrLen.uint32 shl 24)
  nimFwDbgRxuPnAcceptTracePnLo[pnAcceptTraceSlot] = env.secInfo0
  nimFwDbgRxuPnAcceptTracePnHi[pnAcceptTraceSlot] = env.secInfo1
  nimFwDbgRxuPnAcceptTraceStoredLo[pnAcceptTraceSlot] = nimFwDbgRxuPnStoredLo
  nimFwDbgRxuPnAcceptTraceStoredHi[pnAcceptTraceSlot] = nimFwDbgRxuPnStoredHi
  nimFwDbgRxuPnAcceptTraceNextLo[pnAcceptTraceSlot] = nimFwDbgRxuPnNextLo
  nimFwDbgRxuPnAcceptTraceNextHi[pnAcceptTraceSlot] = nimFwDbgRxuPnNextHi
  nimFwDbgRxuPnAcceptTraceSnapLo[pnAcceptTraceSlot] = rxSnapTraceLo(msdu)
  nimFwDbgRxuPnAcceptTraceSnapHi[pnAcceptTraceSlot] = rxSnapTraceHi(msdu)
  nimFwDbgRxuPnAcceptTraceUdp0[pnAcceptTraceSlot] = 0
  nimFwDbgRxuPnAcceptTraceBootpYiaddr[pnAcceptTraceSlot] = 0
  nimFwDbgRxuPnAcceptTraceDhcpMsg[pnAcceptTraceSlot] = 0
  nimFwDbgRxuPnAcceptTraceDhcpServer[pnAcceptTraceSlot] = 0
  if frameLen.uint32 >= machdrLen.uint32 + sizeof(LlcSnapHeaderView).uint32:
    let msduLen = frameLen.uint32 - machdrLen.uint32
    let ipPayload = cast[ptr UncheckedArray[uint8]](rxMsduPayload(msduView))
    if rxSnapIsRfc1042(msdu) and msdu.ethertype == 0x0008'u16 and msduLen >= 28'u32:
      let ihl = (ipPayload[0].uint32 and 0x0F'u32) shl 2
      if ihl >= 20'u32 and msduLen >= sizeof(LlcSnapHeaderView).uint32 + ihl + 8'u32:
        let udp = cast[pointer](cast[uint](ipPayload) + ihl.uint)
        nimFwDbgRxuPnAcceptTraceUdp0[pnAcceptTraceSlot] = debugLoadLe32(udp)
        if msduLen >= sizeof(LlcSnapHeaderView).uint32 + ihl + 32'u32:
          let bootp = cast[pointer](cast[uint](udp) + 8'u)
          nimFwDbgRxuPnAcceptTraceBootpYiaddr[pnAcceptTraceSlot] =
            debugLoadLe32(cast[pointer](cast[uint](bootp) + 16'u))
          if msduLen >= sizeof(LlcSnapHeaderView).uint32 + ihl + 8'u32 + 240'u32:
            var optOff = cast[uint](bootp) + 240'u
            let optEnd = cast[uint](ipPayload) + msduLen.uint
            var guard = 0
            while optOff < optEnd and guard < 64:
              inc guard
              let code = cast[ptr uint8](optOff)[]
              inc optOff
              if code == 0'u8:
                continue
              if code == 255'u8 or optOff >= optEnd:
                break
              let optLen = cast[ptr uint8](optOff)[]
              inc optOff
              if optOff + optLen.uint > optEnd:
                break
              if code == 53'u8 and optLen >= 1'u8:
                nimFwDbgRxuPnAcceptTraceDhcpMsg[pnAcceptTraceSlot] =
                  cast[ptr uint8](optOff)[].uint32
              elif code == 54'u8 and optLen >= 4'u8:
                nimFwDbgRxuPnAcceptTraceDhcpServer[pnAcceptTraceSlot] =
                  debugLoadLe32(cast[pointer](optOff))
              optOff += optLen.uint
