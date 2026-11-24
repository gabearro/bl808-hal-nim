## Optional port-80 diagnostics. Record header metadata, never packet bodies.

const
  WifiTcpPathEntries* = 1024
  WifiTcpPathPolicyEntries* = 384
  WifiTcpPathPort* {.intdefine.} = 80

type
  TcpPathStage* = enum
    tcpRxHandoff = 1, tcpRxRejected, tcpTxOutput, tcpTxRejected, tcpTxConfirm,
    tcpHttpAccept, tcpHttpPoolFull, tcpHttpRecv, tcpTxFallbackChoice,
    tcpTxDoorbell, tcpTxHardwareDone, tcpTxDmaShape
  TcpPathPacket* = object
    ports*, seq*, ack*, lengthId*: uint32
    ipv4Length*: uint16
    flags*: uint8
  TcpPathEntry* = array[7, uint32]
  TcpPathPolicy* = object
    control*: array[8, uint32]
    power*: array[4, uint32]
  TcpPathPolicyEntry* = object
    ordinal*: uint32
    policy*: TcpPathPolicy

static: doAssert sizeof(TcpPathPolicyEntry) == 13 * sizeof(uint32)

func tcpPathFallbackTreatment*(packet: TcpPathPacket): bool {.inline.} =
  let port = packet.ports shr 16
  ((port xor (port shr 4) xor (port shr 8)) and 1) != 0

func tcpDoorbellDetail*(seqCtrl: uint16; ac, tid: uint8; appended: bool): uint32 {.inline.} =
  seqCtrl.uint32 or (ac.uint32 shl 16) or (appended.uint32 shl 19) or (tid.uint32 shl 24)

proc observeTcpPath*(frame: pointer; available, wireLength: uint): TcpPathPacket =
  let limit = min(available, wireLength)
  if frame == nil or limit < 54: return
  let b = cast[ptr UncheckedArray[uint8]](frame)
  template be16(i: uint): uint32 = (b[i].uint32 shl 8) or b[i + 1].uint32
  template be32(i: uint): uint32 = (be16(i) shl 16) or be16(i + 2)
  if be16(12) != 0x0800 or (b[14] shr 4) != 4 or b[23] != 6 or
      (be16(20) and 0x3FFF) != 0:
    return
  let ihl = (b[14] and 15).uint * 4
  let ipLength = be16(16).uint
  let tcp = 14 + ihl
  if ihl < 20 or limit < tcp + 20 or ipLength < ihl + 20 or ipLength > wireLength - 14:
    return
  let tcpLength = (b[tcp + 12] shr 4).uint * 4
  if tcpLength < 20 or tcpLength > ipLength - ihl: return
  let src = be16(tcp)
  let dst = be16(tcp + 2)
  if src != WifiTcpPathPort.uint32 and dst != WifiTcpPathPort.uint32: return
  result = TcpPathPacket(ports: src or (dst shl 16), seq: be32(tcp + 4),
    ack: be32(tcp + 8), lengthId: (ipLength - ihl - tcpLength).uint32 or (be16(18) shl 16),
    ipv4Length: ipLength.uint16, flags: b[tcp + 13])

proc tcpPathEntry*(packet: TcpPathPacket; stage: TcpPathStage;
                   tick, detail: uint32; repush: uint8 = 0;
                   hasPolicy = false): TcpPathEntry {.inline.} =
  [tick, stage.ord.uint32 or (packet.flags.uint32 shl 8) or
   (hasPolicy.uint32 shl 16) or (repush.uint32 shl 24), packet.ports,
   packet.seq, packet.ack, packet.lengthId, detail]

when defined(bl808m0) and defined(bl808WifiDiagTcpPath):
  import ../[core, memmap, mmio]
  static: doAssert defined(bl808AllcoreWasmHttp), "TCP trace needs the all-core PSRAM layout"
  {.pragma: tcpTraceRam, codegenDecl: "$# $# __attribute__((section(\".psrambss.tcp_path\"), aligned(32), used))".}
  var
    wifiTcpPathHead {.exportc: "nimfw_tcp_path_head", volatile.}: uint32
    wifiTcpPathRing {.exportc: "nimfw_tcp_path_ring", tcpTraceRam.}:
      array[WifiTcpPathEntries, TcpPathEntry]
    wifiTcpPathPolicyHead {.exportc: "nimfw_tcp_path_policy_head", volatile.}: uint32
    wifiTcpPathPolicyRing {.exportc: "nimfw_tcp_path_policy_ring", tcpTraceRam.}:
      array[WifiTcpPathPolicyEntries, TcpPathPolicyEntry]

  proc tcpPathTick*(): uint32 {.inline.} = regRead(ClicMtimeBase)

  proc logTcpPathAt*(packet: TcpPathPacket; stage: TcpPathStage; tick, detail: uint32;
                     repush: uint8 = 0; policy: ptr TcpPathPolicy = nil) =
    if packet.ports == 0: return
    let saved = csrReadMstatus()
    disableInterrupts()
    {.emit: "__asm__ volatile(\"\" ::: \"memory\");".}
    let head = wifiTcpPathHead
    if policy != nil:
      let policyHead = wifiTcpPathPolicyHead
      let row = addr wifiTcpPathPolicyRing[policyHead mod WifiTcpPathPolicyEntries.uint32]
      row[] = TcpPathPolicyEntry(ordinal: head, policy: policy[])
      dcacheCleanRange(cast[uint](row), sizeof(TcpPathPolicyEntry).uint)
      fenceIo()
      wifiTcpPathPolicyHead = policyHead + 1'u32
    let slot = addr wifiTcpPathRing[head and (WifiTcpPathEntries - 1).uint32]
    slot[] = tcpPathEntry(packet, stage, tick, detail, repush, policy != nil)
    dcacheCleanRange(cast[uint](slot), sizeof(TcpPathEntry).uint)
    fenceIo()
    wifiTcpPathHead = head + 1'u32
    if (saved and 8) != 0: enableInterrupts()

  proc logTcpPath*(packet: TcpPathPacket; stage: TcpPathStage; detail: uint32 = 0;
                   repush: uint8 = 0; policy: ptr TcpPathPolicy = nil) =
    if packet.ports != 0:
      logTcpPathAt(packet, stage, tcpPathTick(), detail, repush, policy)
