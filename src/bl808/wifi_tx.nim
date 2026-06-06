## Nim replacement for the BL808 WiFi host TX path in bl_tx.c.

when defined(bl808m0) and defined(bl808WifiNimFw):
  {.passC: "-Ibuild/bl_iot_sdk_b773b3f/components/network/wifi_manager/bl60x_wifi_driver".}
  {.passC: "-Ibuild/bl_iot_sdk_b773b3f/components/network/wifi_manager/bl60x_wifi_driver/include".}

  const
    RetryLimitReachedBit = 1'u32 shl 16
    FrameRepushablePsBit = 1'u32 shl 19
    FrameRepushableChanBit = 1'u32 shl 20
    FrameSuccessfulTxBit = 1'u32 shl 23
    DescDoneTxBit = 1'u32 shl 31

    BlVifSta = 0
    BlVifAp = 1
    NxRemoteStaStoreMax = 3
    PbufLinkEncapsulationHlen = 48'u16
    EthAlen = 6'u
    EthHdrSize = 14'u16
    LinkOffsetLen = PbufLinkEncapsulationHlen + EthHdrSize

    ErrOk = 0'i8
    ErrBuf = -2'i8
    ErrConn = -11'i8
    ErrIf = -12'i8

    BlHwIpcEnvOff = 48'u
    BlHwVifTableOff = 60'u
    BlHwStaTableOff = 100'u
    BlVifSize = 20'u
    BlVifVifIdxOff = 13'u
    BlVifLinksNumOff = 14'u
    BlVifFixedStaIdxOff = 15'u
    BlVifFcChanOff = 16'u
    BlStaSize = 40'u
    BlStaWaitingListOff = 0'u
    BlStaPendingListOff = 8'u
    BlStaAddrOff = 16'u
    BlStaIsUsedOff = 22'u
    BlStaStaIdxOff = 23'u
    BlStaVifIdxOff = 24'u
    BlStaFcPsOff = 26'u
    BlStaQosOff = 27'u

    TxCfmCbOff = 0'u
    TxCfmCbArgOff = 4'u
    TxCfmSize = 8'u
    TxHdrSize = 24'u
    TxHdrCustomCfmOff = 4'u
    TxHdrStatusOff = 12'u
    TxHdrPbufOff = 16'u
    TxHdrLenOff = 20'u
    TxHdrVifStaRepushOff = 22'u

    KeTxFcVifBitsOff = 0'u
    KeTxFcApFcChanOff = 1'u
    KeTxFcApFcPsStaBitsOff = 2'u
    KeTxFcStaFcChanOff = 3'u
    KeTxFcStaFcPsOff = 4'u

    TxdescHostPadTxdescOff = 12'u
    TxdescUpperHostOff = 4'u
    TxbufHostBufOff = 4'u

  type
    BlHw {.importc: "struct bl_hw", header: "bl_defs.h".} = object
    BlSta {.importc: "struct bl_sta", header: "bl_defs.h".} = object
    BlTxCfm {.importc: "struct bl_tx_cfm", header: "bl_tx.h".} = object
    Pbuf {.importc: "struct pbuf", header: "<lwip/pbuf.h>".} = object
    KeTxFc {.importc: "struct ke_tx_fc", header: "bl_tx.h".} = object
    PbufView {.packed.} = object
      next*: pointer
      payload*: pointer
      totLen*: uint16
      len*: uint16

    EthernetHeaderView {.packed.} = object
      dst*: array[6, uint8]
      src*: array[6, uint8]
      ethertype*: uint16
      payload*: UncheckedArray[uint8]

    Ipv4HeaderView {.packed.} = object
      versionIhl*: uint8
      dscpEcn*: uint8
      totalLen*: uint16
      identification*: uint16
      flagsFrag*: uint16
      ttl*: uint8
      protocol*: uint8
      checksum*: uint16
      srcAddr*: uint32
      dstAddr*: uint32
      optionsAndPayload*: UncheckedArray[uint8]

    UdpHeaderView {.packed.} = object
      srcPort*: uint16
      dstPort*: uint16
      len*: uint16
      checksum*: uint16
      payload*: UncheckedArray[uint8]

    CoListView {.packed.} = object
      first*: pointer
      last*: pointer

    BlVifView {.packed.} = object
      reserved0*: array[13, uint8]
      vifIdx*: uint8
      linksNum*: uint8
      fixedStaIdx*: uint8
      fcChan*: uint8
      reserved17*: array[3, uint8]

    BlStaView {.packed.} = object
      waitingList*: CoListView
      pendingList*: CoListView
      macAddr*: array[6, uint8]
      isUsed*: uint8
      staIdx*: uint8
      vifIdx*: uint8
      reserved25*: uint8
      fcPs*: uint8
      qos*: uint8
      reserved28*: array[12, uint8]

    BlHwView {.packed.} = object
      reserved0*: array[48, uint8]
      ipcEnv*: pointer
      reserved52*: array[8, uint8]
      vifs*: array[2, BlVifView]
      stas*: array[NxRemoteStaStoreMax, BlStaView]

    KeTxFcView {.packed.} = object
      vifBits*: uint8
      apFcChan*: uint8
      apFcPsStaBits*: uint8
      staFcChan*: uint8
      staFcPs*: uint8

    TxHdrView {.packed.} = object
      linkNext*: pointer
      cfmCb*: pointer
      cfmArg*: pointer
      status*: uint32
      pbuf*: pointer
      len*: uint16
      vifStaRepush*: uint8
      repush*: uint8

    TxbufView {.packed.} = object
      reserved0*: array[4, uint8]
      hostBuf*: UncheckedArray[uint8]

    HostTxDescView {.packed.} = object
      pbufAddr*: uint32
      packetAddr*: uint32
      packetLen*: uint16
      reserved10*: array[2, uint8]
      statusAddr*: uint32
      ethDest*: array[6, uint8]
      ethSrc*: array[6, uint8]
      ethertype*: uint16
      reserved30*: array[12, uint8]
      tid*: uint8
      vifIdx*: uint8
      vifType*: uint8
      staId*: uint8
      flags*: uint16
      pbufChainedPtr*: uint32
      reserved52*: array[12, uint8]
      pbufChainedLen*: uint32

    TxdescHostView {.packed.} = object
      reserved0*: array[12, uint8]
      pad*: array[4, uint8]
      upperHost*: HostTxDescView

    TxCallback = proc(cbArg: pointer; txOk: bool) {.cdecl.}

  {.emit: "extern struct bl_hw wifi_hw;".}
  var wifi_hw {.importc, header: "bl_defs.h".}: BlHw
  var internel_cal_size_tx_hdr* {.exportc.}: cint = TxHdrSize.cint
  var txCntrlStaTrigger: uint32
  var txCntrlStaTriggerPending: uint32
  var nimFwDbgDhcpTx* {.exportc: "nimfw_dbg_dhcp_tx".}: uint32
  var nimFwDbgDhcpTxEth* {.exportc: "nimfw_dbg_dhcp_tx_eth".}: uint32
  var nimFwDbgDhcpTxPorts* {.exportc: "nimfw_dbg_dhcp_tx_ports".}: uint32
  var nimFwDbgDhcpTxLen* {.exportc: "nimfw_dbg_dhcp_tx_len".}: uint32
  var nimFwDbgDhcpTxSrcLo* {.exportc: "nimfw_dbg_dhcp_tx_src_lo".}: uint32
  var nimFwDbgDhcpTxSrcHi* {.exportc: "nimfw_dbg_dhcp_tx_src_hi".}: uint32
  var nimFwDbgDhcpTxMsg* {.exportc: "nimfw_dbg_dhcp_tx_msg".}: uint32
  var nimFwDbgDhcpTxRawLen* {.exportc: "nimfw_dbg_dhcp_tx_raw_len".}: uint32
  var nimFwDbgDhcpTxRaw* {.exportc: "nimfw_dbg_dhcp_tx_raw".}: array[384, uint8]
  var nimFwDbgDhcpTxBreakHits* {.exportc: "nimfw_dbg_dhcp_tx_break_hits".}: uint32
  var nimFwDbgDhcpRequestTxBreakHits* {.exportc: "nimfw_dbg_dhcp_request_tx_break_hits".}: uint32
  var nimFwDbgDhcpTxMsgHist* {.exportc: "nimfw_dbg_dhcp_tx_msg_hist".}: array[8, uint32]
  var nimFwDbgDhcpUdpChecksumRepair* {.exportc: "nimfw_dbg_dhcp_udp_csum_repair".}: uint32
  var nimFwDbgDhcpUdpChecksumBefore* {.exportc: "nimfw_dbg_dhcp_udp_csum_before".}: uint32
  var nimFwDbgDhcpUdpChecksumCalc* {.exportc: "nimfw_dbg_dhcp_udp_csum_calc".}: uint32
  var nimFwDbgDhcpUdpChecksumAfter* {.exportc: "nimfw_dbg_dhcp_udp_csum_after".}: uint32
  var nimFwDbgDhcpUdpChecksumVerifyBefore* {.exportc: "nimfw_dbg_dhcp_udp_csum_vbefore".}: uint32
  var nimFwDbgDhcpUdpChecksumVerifyAfter* {.exportc: "nimfw_dbg_dhcp_udp_csum_vafter".}: uint32
  var nimFwDbgDhcpReqUdpChecksumBefore* {.exportc: "nimfw_dbg_dhcp_req_udp_csum_before".}: uint32
  var nimFwDbgDhcpReqUdpChecksumCalc* {.exportc: "nimfw_dbg_dhcp_req_udp_csum_calc".}: uint32
  var nimFwDbgDhcpReqUdpChecksumAfter* {.exportc: "nimfw_dbg_dhcp_req_udp_csum_after".}: uint32
  var nimFwDbgDhcpReqUdpChecksumVerifyBefore* {.exportc: "nimfw_dbg_dhcp_req_udp_csum_vbefore".}: uint32
  var nimFwDbgDhcpReqUdpChecksumVerifyAfter* {.exportc: "nimfw_dbg_dhcp_req_udp_csum_vafter".}: uint32
  var nimFwDbgDhcpReqUdpChecksumAtCopy* {.exportc: "nimfw_dbg_dhcp_req_udp_csum_at_copy".}: uint32
  var nimFwDbgDhcpCfm* {.exportc: "nimfw_dbg_dhcp_cfm".}: uint32
  var nimFwDbgDhcpCfmOk* {.exportc: "nimfw_dbg_dhcp_cfm_ok".}: uint32
  var nimFwDbgDhcpCfmFail* {.exportc: "nimfw_dbg_dhcp_cfm_fail".}: uint32
  var nimFwDbgDhcpCfmAckOk* {.exportc: "nimfw_dbg_dhcp_cfm_ack_ok".}: uint32
  var nimFwDbgDhcpCfmAckFail* {.exportc: "nimfw_dbg_dhcp_cfm_ack_fail".}: uint32
  var nimFwDbgDhcpCfmStatus* {.exportc: "nimfw_dbg_dhcp_cfm_status".}: uint32
  var nimFwDbgDhcpCfmRingIdx* {.exportc: "nimfw_dbg_dhcp_cfm_ring_idx".}: uint32
  var nimFwDbgDhcpCfmStatusLog* {.exportc: "nimfw_dbg_dhcp_cfm_status_log".}: array[8, uint32]
  var nimFwDbgDhcpCfmMetaLog* {.exportc: "nimfw_dbg_dhcp_cfm_meta_log".}: array[8, uint32]
  var nimFwDbgEapolCfmRingIdx {.importc: "nimfw_dbg_eapol_cfm_ring_idx".}: uint32
  var nimFwDbgEapolCfmStatusLog {.importc: "nimfw_dbg_eapol_cfm_status_log".}: array[4, uint32]
  var nimFwDbgEapolCfmMetaLog {.importc: "nimfw_dbg_eapol_cfm_meta_log".}: array[4, uint32]
  var nimFwDbgEapolCfmKeyLog {.importc: "nimfw_dbg_eapol_cfm_key_log".}: array[4, uint32]
  var nimFwDbgEapolCfmReplayLog {.importc: "nimfw_dbg_eapol_cfm_replay_log".}: array[4, uint32]
  var nimFwDbgEapolCfmCbLog {.importc: "nimfw_dbg_eapol_cfm_cb_log".}: array[4, uint32]
  var nimFwDbgTxStaLookup* {.exportc: "nimfw_dbg_tx_sta_lookup".}: uint32
  var nimFwDbgTxStaLookupFail* {.exportc: "nimfw_dbg_tx_sta_lookup_fail".}: uint32
  var nimFwDbgTxStaLookupMode* {.exportc: "nimfw_dbg_tx_sta_lookup_mode".}: uint32
  var nimFwDbgTxStaLookupVif* {.exportc: "nimfw_dbg_tx_sta_lookup_vif".}: uint32
  var nimFwDbgTxStaLookupSta* {.exportc: "nimfw_dbg_tx_sta_lookup_sta".}: uint32
  var nimFwDbgTxStaLookupResult* {.exportc: "nimfw_dbg_tx_sta_lookup_result".}: uint32
  var nimFwDbgTxStaLookupEth* {.exportc: "nimfw_dbg_tx_sta_lookup_eth".}: uint32
  var nimFwDbgTxStaLookupDst0* {.exportc: "nimfw_dbg_tx_sta_lookup_dst0".}: uint32
  var nimFwDbgTxStaLookupDst1* {.exportc: "nimfw_dbg_tx_sta_lookup_dst1".}: uint32
  var nimFwDbgTxArp* {.exportc: "nimfw_dbg_tx_arp".}: uint32
  var nimFwDbgTxUdp* {.exportc: "nimfw_dbg_tx_udp".}: uint32
  var nimFwDbgTxUdpProbe* {.exportc: "nimfw_dbg_tx_udp_probe".}: uint32
  var nimFwDbgTxUdpPorts* {.exportc: "nimfw_dbg_tx_udp_ports".}: uint32
  var nimFwDbgTxUdpIp* {.exportc: "nimfw_dbg_tx_udp_ip".}: uint32
  var nimFwDbgTxTcp* {.exportc: "nimfw_dbg_tx_tcp".}: uint32
  var nimFwDbgTxTcp80* {.exportc: "nimfw_dbg_tx_tcp80".}: uint32
  var nimFwDbgTxTcpFlags* {.exportc: "nimfw_dbg_tx_tcp_flags".}: uint32

  proc c_memset(s: pointer; c: cint; n: csize_t): pointer
    {.importc: "memset", header: "<string.h>", cdecl.}
  proc c_memcpy(dest, src: pointer; n: csize_t): pointer
    {.importc: "memcpy", header: "<string.h>", cdecl.}
  proc c_memcmp(a, b: pointer; n: csize_t): cint
    {.importc: "memcmp", header: "<string.h>", cdecl.}
  proc bl_os_printf(fmt: cstring)
    {.importc, header: "bl_os_private.h", cdecl, varargs.}
  proc bl_os_enter_critical()
    {.importc, header: "bl_os_private.h", cdecl.}
  proc bl_os_exit_critical()
    {.importc, header: "bl_os_private.h", cdecl.}
  proc bl_irq_handler() {.importc, cdecl, header: "bl_irqs.h".}
  proc ipc_host_txdesc_get(env: pointer): pointer {.importc, cdecl, header: "ipc_host.h".}
  proc ipc_host_txdesc_push(env, hostId: pointer) {.importc, cdecl, header: "ipc_host.h".}
  proc ipc_host_txbuf_get(env: pointer): pointer {.importc, cdecl, header: "ipc_host.h".}
  proc ipc_host_txbuf_free(buf: pointer) {.importc, cdecl, header: "ipc_host.h".}
  proc pbuf_header(p: ptr Pbuf; headerSizeIncrement: int16): uint8
    {.importc, cdecl, header: "<lwip/pbuf.h>".}
  proc pbuf_ref(p: ptr Pbuf) {.importc, cdecl, header: "<lwip/pbuf.h>".}
  proc pbuf_free(p: ptr Pbuf): uint8 {.importc, cdecl, header: "<lwip/pbuf.h>".}

  proc zero(p: pointer; n: uint) {.inline.} =
    discard c_memset(p, 0, n.csize_t)

  proc copyMem(dest, src: pointer; n: uint) {.inline.} =
    if dest != nil and src != nil and n != 0:
      discard c_memcpy(dest, src, n.csize_t)

  template pbufView(p: pointer): ptr PbufView =
    cast[ptr PbufView](p)

  template ethernetHeaderAt(p: pointer): ptr EthernetHeaderView =
    cast[ptr EthernetHeaderView](p)

  template hostTxDescAt(p: pointer): ptr HostTxDescView =
    cast[ptr HostTxDescView](p)

  template coListAt(p: pointer): ptr CoListView =
    cast[ptr CoListView](p)

  template hwView(): ptr BlHwView =
    cast[ptr BlHwView](addr wifi_hw)

  template vifView(p: pointer): ptr BlVifView =
    cast[ptr BlVifView](p)

  template staView(p: pointer): ptr BlStaView =
    cast[ptr BlStaView](p)

  template keTxFcView(p: pointer): ptr KeTxFcView =
    cast[ptr KeTxFcView](p)

  template txHdrView(p: pointer): ptr TxHdrView =
    cast[ptr TxHdrView](p)

  template txbufView(p: pointer): ptr TxbufView =
    cast[ptr TxbufView](p)

  template txdescHostView(p: pointer): ptr TxdescHostView =
    cast[ptr TxdescHostView](p)

  template ipv4HeaderAt(eth: ptr EthernetHeaderView): ptr Ipv4HeaderView =
    cast[ptr Ipv4HeaderView](addr eth.payload[0])

  template byteView(p: pointer): ptr UncheckedArray[uint8] =
    cast[ptr UncheckedArray[uint8]](p)

  proc bufferAt(base: pointer; off: uint): pointer {.inline.} =
    cast[pointer](addr byteView(base)[off])

  proc txbufHostBuf(p: pointer): pointer {.inline.} =
    cast[pointer](addr txbufView(p).hostBuf[0])

  proc txdescHostPad(p: pointer): pointer {.inline.} =
    cast[pointer](addr txdescHostView(p).pad[0])

  proc txdescUpperHost(p: pointer): ptr HostTxDescView {.inline.} =
    addr txdescHostView(p).upperHost

  proc udpHeaderAt(ip: ptr Ipv4HeaderView): ptr UdpHeaderView {.inline.} =
    let ihlWords = ip.versionIhl and 0x0f'u8
    if ihlWords < 5'u8:
      return nil
    cast[ptr UdpHeaderView](addr ip.optionsAndPayload[(ihlWords - 5'u8).uint * 4'u])

  proc isDhcpUdp(eth: ptr EthernetHeaderView): bool {.inline.} =
    if eth.ethertype != 0x0008'u16:
      return false
    let ip = ipv4HeaderAt(eth)
    if ip.protocol != 17'u8:
      return false
    let udp = udpHeaderAt(ip)
    udp != nil and (udp.srcPort == 0x4400'u16 or udp.dstPort == 0x4300'u16)

  proc loadBe16(p: ptr UncheckedArray[uint8]; off: uint): uint16 {.inline.} =
    (p[off].uint16 shl 8) or p[off + 1'u].uint16

  proc loadBe32(p: ptr UncheckedArray[uint8]; off: uint): uint32 {.inline.} =
    (p[off].uint32 shl 24) or (p[off + 1'u].uint32 shl 16) or
      (p[off + 2'u].uint32 shl 8) or p[off + 3'u].uint32

  proc storeBe16(p: ptr UncheckedArray[uint8]; off: uint; value: uint16) {.inline.} =
    p[off] = (value shr 8).uint8
    p[off + 1'u] = value.uint8

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

  proc repairDhcpUdpChecksum(raw: ptr UncheckedArray[uint8]; len: uint32): uint8 =
    const IpOff = 14'u
    if len < 42'u32 or loadBe16(raw, 12'u) != 0x0800'u16:
      return 0'u8
    let versionIhl = raw[IpOff]
    if (versionIhl shr 4) != 4'u8 or raw[IpOff + 9'u] != 17'u8:
      return 0'u8
    let ihl = (versionIhl and 0x0f'u8).uint * 4'u
    if ihl < 20'u or len.uint < IpOff + ihl + 8'u:
      return 0'u8
    let udpOff = IpOff + ihl
    let srcPort = loadBe16(raw, udpOff)
    let dstPort = loadBe16(raw, udpOff + 2'u)
    if not ((srcPort == 68'u16 and dstPort == 67'u16) or
            (srcPort == 67'u16 and dstPort == 68'u16)):
      return 0'u8
    let udpLen = loadBe16(raw, udpOff + 4'u)
    if udpLen < 8'u16 or len.uint < udpOff + udpLen.uint:
      return 0'u8
    let before = loadBe16(raw, udpOff + 6'u)
    let verifyBefore = verifyUdpPacket(raw, IpOff, udpOff, udpLen)
    let calc = checksumUdpPacket(raw, IpOff, udpOff, udpLen, true)
    storeBe16(raw, udpOff + 6'u, calc)
    let verifyAfter = verifyUdpPacket(raw, IpOff, udpOff, udpLen)
    inc nimFwDbgDhcpUdpChecksumRepair
    nimFwDbgDhcpUdpChecksumBefore = before.uint32
    nimFwDbgDhcpUdpChecksumCalc = calc.uint32
    nimFwDbgDhcpUdpChecksumAfter = loadBe16(raw, udpOff + 6'u).uint32
    nimFwDbgDhcpUdpChecksumVerifyBefore = verifyBefore.uint32
    nimFwDbgDhcpUdpChecksumVerifyAfter = verifyAfter.uint32
    1'u8

  proc udpChecksumFieldFromEthernet(raw: ptr UncheckedArray[uint8]; len: uint32): uint16 =
    const IpOff = 14'u
    if len < 42'u32 or loadBe16(raw, 12'u) != 0x0800'u16:
      return 0'u16
    let versionIhl = raw[IpOff]
    if (versionIhl shr 4) != 4'u8:
      return 0'u16
    let ihl = (versionIhl and 0x0f'u8).uint * 4'u
    if ihl < 20'u or len.uint < IpOff + ihl + 8'u:
      return 0'u16
    loadBe16(raw, IpOff + ihl + 6'u)

  proc dhcpMsgTypeFromEthernet(raw: ptr UncheckedArray[uint8]; len: uint32): uint8 =
    if len <= 282'u32 or loadBe32(raw, 278'u) != 0x63825363'u32:
      return 0'u8
    var off = 282'u
    while off + 1'u < len.uint:
      let opt = raw[off]
      if opt == 0xff'u8:
        break
      if opt == 0'u8:
        inc off
        continue
      let optLen = raw[off + 1'u]
      if off + 2'u + optLen.uint > len.uint:
        break
      if opt == 53'u8 and optLen >= 1'u8:
        return raw[off + 2'u]
      off += 2'u + optLen.uint
    0'u8

  static:
    doAssert sizeof(PbufView) == 12
    doAssert offsetof(PbufView, payload) == 4
    doAssert offsetof(PbufView, totLen) == 8
    doAssert offsetof(PbufView, len) == 10
    doAssert sizeof(EthernetHeaderView) == 14
    doAssert offsetof(EthernetHeaderView, src) == 6
    doAssert offsetof(EthernetHeaderView, ethertype) == 12
    doAssert offsetof(Ipv4HeaderView, protocol) == 9
    doAssert offsetof(Ipv4HeaderView, optionsAndPayload) == 20
    doAssert sizeof(UdpHeaderView) == 8
    doAssert offsetof(UdpHeaderView, dstPort) == 2
    doAssert sizeof(CoListView) == 8
    doAssert offsetof(BlVifView, vifIdx) == int(BlVifVifIdxOff)
    doAssert offsetof(BlVifView, linksNum) == int(BlVifLinksNumOff)
    doAssert offsetof(BlVifView, fixedStaIdx) == int(BlVifFixedStaIdxOff)
    doAssert offsetof(BlVifView, fcChan) == int(BlVifFcChanOff)
    doAssert offsetof(BlStaView, waitingList) == int(BlStaWaitingListOff)
    doAssert offsetof(BlStaView, pendingList) == int(BlStaPendingListOff)
    doAssert offsetof(BlStaView, macAddr) == int(BlStaAddrOff)
    doAssert offsetof(BlStaView, isUsed) == int(BlStaIsUsedOff)
    doAssert offsetof(BlStaView, staIdx) == int(BlStaStaIdxOff)
    doAssert offsetof(BlStaView, vifIdx) == int(BlStaVifIdxOff)
    doAssert offsetof(BlStaView, fcPs) == int(BlStaFcPsOff)
    doAssert offsetof(BlStaView, qos) == int(BlStaQosOff)
    doAssert offsetof(BlHwView, ipcEnv) == int(BlHwIpcEnvOff)
    doAssert offsetof(BlHwView, vifs) == int(BlHwVifTableOff)
    doAssert offsetof(BlHwView, stas) == int(BlHwStaTableOff)
    doAssert offsetof(KeTxFcView, vifBits) == int(KeTxFcVifBitsOff)
    doAssert offsetof(KeTxFcView, apFcChan) == int(KeTxFcApFcChanOff)
    doAssert offsetof(KeTxFcView, apFcPsStaBits) == int(KeTxFcApFcPsStaBitsOff)
    doAssert offsetof(KeTxFcView, staFcChan) == int(KeTxFcStaFcChanOff)
    doAssert offsetof(KeTxFcView, staFcPs) == int(KeTxFcStaFcPsOff)
    doAssert offsetof(TxHdrView, cfmCb) == int(TxHdrCustomCfmOff + TxCfmCbOff)
    doAssert offsetof(TxHdrView, cfmArg) == int(TxHdrCustomCfmOff + TxCfmCbArgOff)
    doAssert offsetof(TxHdrView, status) == int(TxHdrStatusOff)
    doAssert offsetof(TxHdrView, pbuf) == int(TxHdrPbufOff)
    doAssert offsetof(TxHdrView, len) == int(TxHdrLenOff)
    doAssert offsetof(TxHdrView, vifStaRepush) == int(TxHdrVifStaRepushOff)
    doAssert offsetof(TxbufView, hostBuf) == int(TxbufHostBufOff)
    doAssert offsetof(TxdescHostView, pad) == int(TxdescHostPadTxdescOff)
    doAssert offsetof(TxdescHostView, upperHost) == int(TxdescHostPadTxdescOff + TxdescUpperHostOff)
    doAssert offsetof(HostTxDescView, pbufAddr) == 0
    doAssert offsetof(HostTxDescView, packetAddr) == 4
    doAssert offsetof(HostTxDescView, packetLen) == 8
    doAssert offsetof(HostTxDescView, statusAddr) == 12
    doAssert offsetof(HostTxDescView, ethDest) == 16
    doAssert offsetof(HostTxDescView, ethSrc) == 22
    doAssert offsetof(HostTxDescView, ethertype) == 28
    doAssert offsetof(HostTxDescView, tid) == 42
    doAssert offsetof(HostTxDescView, vifIdx) == 43
    doAssert offsetof(HostTxDescView, vifType) == 44
    doAssert offsetof(HostTxDescView, staId) == 45
    doAssert offsetof(HostTxDescView, flags) == 46
    doAssert offsetof(HostTxDescView, pbufChainedPtr) == 48
    doAssert offsetof(HostTxDescView, pbufChainedLen) == 64

  proc listEmpty(list: pointer): bool {.inline.} =
    coListAt(list).first == nil

  proc listPushBack(list, item: pointer) =
    if list == nil or item == nil:
      return
    txHdrView(item).linkNext = nil
    let q = coListAt(list)
    let last = q.last
    if last == nil:
      q.first = item
    else:
      txHdrView(last).linkNext = item
    q.last = item

  proc listPopFront(list: pointer): pointer =
    if list == nil:
      return nil
    let q = coListAt(list)
    result = q.first
    if result != nil:
      let next = txHdrView(result).linkNext
      q.first = next
      if next == nil:
        q.last = nil
      txHdrView(result).linkNext = nil

  proc alignPads(p: pointer): uint16 {.inline.} =
    ((4'u - (cast[uint](p) and 3'u)) and 3'u).uint16

  proc vifAt(idx: int): pointer {.inline.} =
    cast[pointer](addr hwView().vifs[idx])

  proc staAt(idx: int): pointer {.inline.} =
    cast[pointer](addr hwView().stas[idx])

  proc staVif(sta: pointer): pointer {.inline.} =
    vifAt(staView(sta).vifIdx.int)

  proc txHdrLen(txhdr: pointer): uint16 {.inline.} =
    txHdrView(txhdr).len

  proc setTxHdrLen(txhdr: pointer; value: uint16) {.inline.} =
    txHdrView(txhdr).len = value

  proc txHdrVifType(txhdr: pointer): uint8 {.inline.} =
    txHdrView(txhdr).vifStaRepush and 0x0f'u8

  proc setTxHdrVifType(txhdr: pointer; value: uint8) {.inline.} =
    let hdr = txHdrView(txhdr)
    hdr.vifStaRepush = (hdr.vifStaRepush and 0xf0'u8) or (value and 0x0f'u8)

  proc txHdrStaId(txhdr: pointer): uint8 {.inline.} =
    (txHdrView(txhdr).vifStaRepush shr 4) and 0x0f'u8

  proc setTxHdrStaId(txhdr: pointer; value: uint8) {.inline.} =
    let hdr = txHdrView(txhdr)
    hdr.vifStaRepush = (hdr.vifStaRepush and 0x0f'u8) or ((value and 0x0f'u8) shl 4)

  proc txHdrRepush(txhdr: pointer): uint8 {.inline.} =
    txHdrView(txhdr).repush

  proc setTxHdrRepush(txhdr: pointer; value: uint8) {.inline.} =
    txHdrView(txhdr).repush = value

  proc bitSta(idx: uint8): uint32 {.inline.} =
    1'u32 shl idx

  proc bitSta(idx: int): uint32 {.inline.} =
    1'u32 shl idx

  proc bitVif(idx: int): uint8 {.inline.} =
    1'u8 shl idx

  proc isBcMc(firstByte: uint8): bool {.inline.} =
    (firstByte and 1'u8) != 0'u8

  proc txCntrlCheckFc(sta: pointer): bool =
    staView(sta).fcPs == 0'u8 and vifView(staVif(sta)).fcChan == 0'u8

  proc txCntrlUpdateFc(txFcField: pointer): uint32 =
    let fc = keTxFcView(txFcField)
    for i in 0 ..< 2:
      if (fc.vifBits and bitVif(i)) != 0'u8:
        if i == BlVifSta:
          let vif = vifView(vifAt(BlVifSta))
          let fixedStaIdx = vif.fixedStaIdx
          if fc.staFcChan != 0'u8:
            vif.fcChan = 0
          if fc.staFcPs != 0'u8:
            staView(staAt(fixedStaIdx.int)).fcPs = 0
          result = result or bitSta(fixedStaIdx)
        else:
          let vif = vifView(vifAt(BlVifAp))
          let fixedStaIdx = vif.fixedStaIdx
          if fc.apFcChan != 0'u8:
            vif.fcChan = 0
            result = result or bitSta(fixedStaIdx)
          result = result or fc.apFcPsStaBits.uint32

  proc txCntrlGetStaId(isSta: int; isBroadcast: bool; macAddr: pointer): int =
    inc nimFwDbgTxStaLookup
    nimFwDbgTxStaLookupMode = isSta.uint32 or
      (if isBroadcast: 0x100'u32 else: 0'u32)
    if isSta != 0:
      let vif = vifView(vifAt(BlVifSta))
      let apIdx = vif.fixedStaIdx
      nimFwDbgTxStaLookupVif = vif.linksNum.uint32 or
        (apIdx.uint32 shl 8) or
        (vif.fcChan.uint32 shl 16) or
        (vif.vifIdx.uint32 shl 24)
      if apIdx >= NxRemoteStaStoreMax.uint8:
        inc nimFwDbgTxStaLookupFail
        nimFwDbgTxStaLookupSta = 0x80000000'u32 or apIdx.uint32
        nimFwDbgTxStaLookupResult = 0xffffffff'u32
        return -1
      let sta = staView(staAt(apIdx.int))
      nimFwDbgTxStaLookupSta = sta.isUsed.uint32 or
        (sta.staIdx.uint32 shl 8) or
        (sta.vifIdx.uint32 shl 16) or
        (sta.qos.uint32 shl 24)
      if vif.linksNum != 0'u8 and sta.isUsed != 0'u8:
        nimFwDbgTxStaLookupResult = sta.staIdx.uint32
        return sta.staIdx.int
      inc nimFwDbgTxStaLookupFail
      nimFwDbgTxStaLookupResult = 0xffffffff'u32
      return -1

    let apVif = vifView(vifAt(BlVifAp))
    if apVif.linksNum == 0'u8:
      inc nimFwDbgTxStaLookupFail
      nimFwDbgTxStaLookupVif = apVif.linksNum.uint32 or
        (apVif.fixedStaIdx.uint32 shl 8) or
        (apVif.fcChan.uint32 shl 16) or
        (apVif.vifIdx.uint32 shl 24)
      nimFwDbgTxStaLookupResult = 0xffffffff'u32
      return -1

    let bcmcStaIdx = apVif.fixedStaIdx.int
    if isBroadcast:
      let sta = staView(staAt(bcmcStaIdx))
      nimFwDbgTxStaLookupSta = sta.isUsed.uint32 or
        (sta.staIdx.uint32 shl 8) or
        (sta.vifIdx.uint32 shl 16) or
        (sta.qos.uint32 shl 24)
      if sta.isUsed != 0'u8:
        nimFwDbgTxStaLookupResult = sta.staIdx.uint32
        return sta.staIdx.int
      inc nimFwDbgTxStaLookupFail
      nimFwDbgTxStaLookupResult = 0xffffffff'u32
      return -1

    for i in 0 ..< NxRemoteStaStoreMax:
      if i == bcmcStaIdx:
        continue
      let sta = staView(staAt(i))
      if sta.isUsed != 0'u8 and
          c_memcmp(cast[pointer](addr sta.macAddr[0]), macAddr, EthAlen.csize_t) == 0:
        nimFwDbgTxStaLookupResult = i.uint32
        return i
    inc nimFwDbgTxStaLookupFail
    nimFwDbgTxStaLookupResult = 0xffffffff'u32
    -1

  proc txCheckRet(isSta, isGroupcast: uint8; value: uint32): int =
    discard isSta
    if (isGroupcast == 0'u8 and (value and FrameSuccessfulTxBit) != 0'u32) or
        (isGroupcast != 0'u8 and (value and DescDoneTxBit) != 0'u32):
      return 1
    0

  proc nimFwDbgDhcpTxBreakpoint*() {.exportc: "nimfw_dbg_dhcp_tx_breakpoint",
      cdecl, noinline.} =
    inc nimFwDbgDhcpTxBreakHits

  proc nimFwDbgDhcpRequestTxBreakpoint*()
      {.exportc: "nimfw_dbg_dhcp_request_tx_breakpoint", cdecl, noinline.} =
    inc nimFwDbgDhcpRequestTxBreakHits

  proc txCntrlPurgeCheck(sta: pointer; onlyCheck: uint8) =
    let staO = staView(sta)
    if not listEmpty(cast[pointer](addr staO.pendingList)) or not listEmpty(cast[pointer](addr staO.waitingList)):
      if onlyCheck != 0:
        bl_os_printf("[TX] Have remaining packets when checking!\n\r")
      else:
        bl_os_enter_critical()
        txCntrlStaTrigger = txCntrlStaTrigger or bitSta(staO.staIdx)
        bl_irq_handler()
        bl_os_exit_critical()

  proc txPush(sta, txdescHost, ptxbuf, txhdr: pointer) =
    zero(txdescHostPad(txdescHost), 208)
    let txbuf = ptxbuf
    let txbufBuf = txbufHostBuf(txbuf)
    var p: pointer = nil
    var ethhdr: pointer

    if txHdrView(txhdr).pbuf != txbuf:
      p = txHdrView(txhdr).pbuf
      ethhdr = bufferAt(pbufView(p).payload, PbufLinkEncapsulationHlen.uint)
    else:
      ethhdr = bufferAt(txbufBuf, PbufLinkEncapsulationHlen.uint)

    let staO = staView(sta)
    let hostDesc = txdescUpperHost(txdescHost)
    let eth = ethernetHeaderAt(ethhdr)
    copyMem(addr hostDesc.ethDest[0], addr eth.dst[0], EthAlen)
    copyMem(addr hostDesc.ethSrc[0], addr eth.src[0], EthAlen)
    hostDesc.ethertype = eth.ethertype
    hostDesc.vifType = txHdrVifType(txhdr)
    hostDesc.packetLen = txHdrLen(txhdr) - LinkOffsetLen
    hostDesc.vifIdx = vifView(staVif(sta)).vifIdx
    hostDesc.staId = staO.staIdx
    hostDesc.tid = if staO.qos != 0'u8: 0'u8 else: 0xff'u8
    hostDesc.packetAddr = 0x1111_1111'u32
    hostDesc.flags = 0

    var newTxhdr = txhdr
    var totalLen: uint16
    if txHdrView(txhdr).pbuf != txbuf:
      let alignSrc = alignPads(pbufView(p).payload)
      let alignDst = alignPads(txbufBuf)
      newTxhdr = bufferAt(txbufBuf, alignDst.uint)
      var q = p
      var loop = 0
      totalLen = 0
      while q != nil:
        let qView = pbufView(q)
        let qPayload = qView.payload
        let qLen = qView.len
        if loop == 0:
          copyMem(bufferAt(txbufBuf, PbufLinkEncapsulationHlen.uint),
                  bufferAt(qPayload, PbufLinkEncapsulationHlen.uint),
                  (qLen - PbufLinkEncapsulationHlen).uint)
        else:
          copyMem(bufferAt(txbufBuf, totalLen.uint), qPayload, qLen.uint)
        totalLen = totalLen + qLen
        inc loop
        q = qView.next
      copyMem(newTxhdr, txhdr, TxHdrSize)
      txHdrView(newTxhdr).pbuf = txbuf
      discard pbuf_free(cast[ptr Pbuf](p))
    else:
      totalLen = txHdrLen(newTxhdr)

    hostDesc.pbufChainedPtr = cast[uint](bufferAt(txbufBuf, LinkOffsetLen.uint)).uint32
    hostDesc.pbufChainedLen = (totalLen - LinkOffsetLen).uint32
    hostDesc.statusAddr = cast[uint](addr txHdrView(newTxhdr).status).uint32
    hostDesc.pbufAddr = cast[uint](txbuf).uint32
    ipc_host_txdesc_push(hwView().ipcEnv, txbuf)

  proc bl_tx_cfm*(pthis, hostId: pointer): cint {.exportc, cdecl.} =
    {.emit: "{ extern volatile unsigned int nimfw_dbg_bl_tx_cfm; nimfw_dbg_bl_tx_cfm++; }".}
    discard pthis
    let buf = txbufHostBuf(hostId)
    let txhdr = bufferAt(buf, alignPads(buf).uint)
    let eth = bufferAt(buf, PbufLinkEncapsulationHlen.uint)
    let ethHdr = ethernetHeaderAt(eth)
    let ethTypeBytes = ethHdr.ethertype
    if ethTypeBytes == 0x8e88'u16 or ethTypeBytes == 0x888e'u16:
      {.emit: "{ extern volatile unsigned int nimfw_dbg_bl_tx_cfm_eapol; nimfw_dbg_bl_tx_cfm_eapol++; }".}
    let value = txHdrView(txhdr).status
    if value == 0'u32:
      bl_os_printf("[TX] FW return status is NULL!!!\n\r")

    let ret = txCheckRet(txHdrVifType(txhdr), if isBcMc(ethHdr.dst[0]): 1'u8 else: 0'u8, value)
    if isDhcpUdp(ethHdr):
      inc nimFwDbgDhcpCfm
      nimFwDbgDhcpCfmStatus = value
      let ringIdx = nimFwDbgDhcpCfmRingIdx and 7'u32
      nimFwDbgDhcpCfmRingIdx = nimFwDbgDhcpCfmRingIdx + 1'u32
      nimFwDbgDhcpCfmStatusLog[ringIdx] = value
      nimFwDbgDhcpCfmMetaLog[ringIdx] =
        (cast[uint32](ret) and 0xff'u32) or
        (txHdrVifType(txhdr).uint32 shl 8) or
        ((if isBcMc(ethHdr.dst[0]): 1'u32 else: 0'u32) shl 16) or
        (txHdrRepush(txhdr).uint32 shl 24)
      if (value and FrameSuccessfulTxBit) != 0'u32:
        inc nimFwDbgDhcpCfmAckOk
      else:
        inc nimFwDbgDhcpCfmAckFail
      if ret > 0:
        inc nimFwDbgDhcpCfmOk
      else:
        inc nimFwDbgDhcpCfmFail
    let sta = staAt(txHdrStaId(txhdr).int)
    let staO = staView(sta)
    let linksNum = vifView(staVif(sta)).linksNum

    if ret == 0 and txHdrRepush(txhdr) < 3'u8 and linksNum != 0'u8 and
        staO.isUsed != 0'u8:
      if (value and RetryLimitReachedBit) != 0'u32:
        txCntrlStaTriggerPending = txCntrlStaTriggerPending or bitSta(staO.staIdx)
      elif (value and FrameRepushableChanBit) != 0'u32:
        vifView(staVif(sta)).fcChan = 1
      elif (value and FrameRepushablePsBit) != 0'u32:
        staO.fcPs = 1
      else:
        discard
      if ((value and (RetryLimitReachedBit or FrameRepushableChanBit or FrameRepushablePsBit)) != 0'u32):
        setTxHdrRepush(txhdr, txHdrRepush(txhdr) + 1'u8)
        listPushBack(cast[pointer](addr staO.pendingList), txhdr)
        return 0

    let cb = cast[TxCallback](txHdrView(txhdr).cfmCb)
    let cbArg = txHdrView(txhdr).cfmArg
    # For EAPOL frames, record the cb pointer + status code so we can see if
    # MAC HW actually got 802.11 ACK from AP.
    if ethTypeBytes == 0x8e88'u16 or ethTypeBytes == 0x888e'u16:
      {.emit: ["{ extern volatile unsigned int nimfw_dbg_cfm_cb_ptr_last; nimfw_dbg_cfm_cb_ptr_last = (unsigned int)", cb, "; extern volatile unsigned int nimfw_dbg_cfm_last_ethertype; nimfw_dbg_cfm_last_ethertype = (unsigned int)", ethTypeBytes, "; extern volatile unsigned int nimfw_dbg_eapol_cfm_status; nimfw_dbg_eapol_cfm_status = (unsigned int)", value, "; extern volatile unsigned int nimfw_dbg_eapol_cfm_count; nimfw_dbg_eapol_cfm_count++; }"].}
      let logIdx = nimFwDbgEapolCfmRingIdx and 0x03'u32
      nimFwDbgEapolCfmRingIdx = nimFwDbgEapolCfmRingIdx + 1'u32
      let eapol = cast[ptr UncheckedArray[uint8]](addr ethHdr.payload[0])
      let eapolLen = if txHdrLen(txhdr) >= LinkOffsetLen: txHdrLen(txhdr) - LinkOffsetLen else: 0'u16
      var keyInfo = 0'u32
      var replayLo = 0'u32
      var eapolKind = 0'u32
      if eapolLen >= 7'u16:
        keyInfo = loadBe16(eapol, 5'u).uint32
        eapolKind = eapol[1].uint32 or (eapol[4].uint32 shl 8)
      if eapolLen >= 17'u16:
        replayLo = loadBe32(eapol, 13'u)
      nimFwDbgEapolCfmStatusLog[logIdx] = value
      nimFwDbgEapolCfmMetaLog[logIdx] =
        eapolLen.uint32 or
        (if ret > 0: 1'u32 shl 16 else: 0'u32) or
        ((txHdrStaId(txhdr).uint32 and 0x0f'u32) shl 24) or
        ((txHdrRepush(txhdr).uint32 and 0x0f'u32) shl 28)
      nimFwDbgEapolCfmKeyLog[logIdx] = keyInfo or (eapolKind shl 16)
      nimFwDbgEapolCfmReplayLog[logIdx] = replayLo
      nimFwDbgEapolCfmCbLog[logIdx] = cast[uint](cb).uint32
      # ret > 0 means MAC HW reports successful TX (with ACK). ret <= 0 = failure.
      if ret > 0:
        {.emit: "{ extern volatile unsigned int nimfw_dbg_eapol_cfm_ack_ok; nimfw_dbg_eapol_cfm_ack_ok++; }".}
      else:
        {.emit: "{ extern volatile unsigned int nimfw_dbg_eapol_cfm_ack_fail; nimfw_dbg_eapol_cfm_ack_fail++; }".}
    if cb != nil:
      {.emit: "{ extern volatile unsigned int nimfw_dbg_bl_tx_cfm_cb; nimfw_dbg_bl_tx_cfm_cb++; }".}
    ipc_host_txbuf_free(hostId)
    txCntrlStaTriggerPending = txCntrlStaTriggerPending or bitSta(staO.staIdx)
    if cb != nil:
      cb(cbArg, ret > 0)
    ret.cint

  proc bl_tx_try_flush*(param: cint; txFcField: ptr KeTxFc) {.exportc, cdecl.} =
    {.emit: "{ extern volatile unsigned int nimfw_dbg_tx_flush_enter; nimfw_dbg_tx_flush_enter++; }".}
    var staTrigger = 0'u32
    if param != 0 and txFcField != nil:
      staTrigger = txCntrlUpdateFc(cast[pointer](txFcField))

    staTrigger = staTrigger or txCntrlStaTriggerPending
    txCntrlStaTriggerPending = 0
    bl_os_enter_critical()
    staTrigger = staTrigger or txCntrlStaTrigger
    txCntrlStaTrigger = 0
    bl_os_exit_critical()

    for i in 0 ..< NxRemoteStaStoreMax:
      if staTrigger == 0'u32:
        break
      let sta = staAt(i)
      let staO = staView(sta)
      if (staTrigger and bitSta(i)) == 0'u32 or not txCntrlCheckFc(sta):
        continue

      while not listEmpty(cast[pointer](addr staO.pendingList)):
        let txdescHost = ipc_host_txdesc_get(hwView().ipcEnv)
        if txdescHost == nil:
          bl_os_printf("[TX] no more txdesc, wait!\n\r")
          break
        let txhdr = listPopFront(cast[pointer](addr staO.pendingList))
        if txhdr == nil:
          break
        txPush(sta, txdescHost, txHdrView(txhdr).pbuf, txhdr)

      while not listEmpty(cast[pointer](addr staO.waitingList)):
        let txdescHost = ipc_host_txdesc_get(hwView().ipcEnv)
        if txdescHost == nil:
          {.emit: "{ extern volatile unsigned int nimfw_dbg_tx_nodesc; nimfw_dbg_tx_nodesc++; }".}
          bl_os_printf("[TX] no more txdesc, wait!\n\r")
          break
        let txbuf = ipc_host_txbuf_get(hwView().ipcEnv)
        if txbuf == nil:
          {.emit: "{ extern volatile unsigned int nimfw_dbg_tx_nobuf; nimfw_dbg_tx_nobuf++; }".}
          bl_os_printf("[TX] no more txbuf, wait!\n\r")
          break
        bl_os_enter_critical()
        let txhdr = listPopFront(cast[pointer](addr staO.waitingList))
        bl_os_exit_critical()
        if txhdr == nil:
          ipc_host_txbuf_free(txbuf)
          break
        {.emit: "{ extern volatile unsigned int nimfw_dbg_tx_push_calls; nimfw_dbg_tx_push_calls++; }".}
        txPush(sta, txdescHost, txbuf, txhdr)

  proc bl_output*(blHw: ptr BlHw; isSta: cint; p: ptr Pbuf; customCfm: ptr BlTxCfm): int8
      {.exportc, cdecl.} =
    if blHw == nil or p == nil:
      bl_os_printf("[TX] NULL parameters!\r\n")
      return ErrConn

    let pbuf = pbufView(cast[pointer](p))
    let ethhdr = pbuf.payload
    let eth = ethernetHeaderAt(ethhdr)
    let proto = eth.ethertype
    if proto == 0x0608'u16:
      inc nimFwDbgTxArp
    elif proto == 0x0008'u16 and pbuf.len.uint32 >= 42'u32:
      let raw = cast[ptr UncheckedArray[uint8]](pbuf.payload)
      let ihl = (raw[14] and 0x0F'u8).uint32 * 4'u32
      let l4Off = 14'u32 + ihl
      if ihl >= 20'u32 and l4Off + 8'u32 <= pbuf.len.uint32 and raw[23] == 17'u8:
        let srcPort = loadBe16(raw, l4Off)
        let dstPort = loadBe16(raw, l4Off + 2'u32)
        inc nimFwDbgTxUdp
        nimFwDbgTxUdpPorts = srcPort.uint32 or (dstPort.uint32 shl 16)
        nimFwDbgTxUdpIp =
          raw[26].uint32 or (raw[27].uint32 shl 8) or
          (raw[30].uint32 shl 16) or (raw[31].uint32 shl 24)
        if srcPort == 65001'u16 or dstPort == 65001'u16:
          inc nimFwDbgTxUdpProbe
      elif ihl >= 20'u32 and l4Off + 14'u32 < pbuf.len.uint32 and raw[23] == 6'u8:
        let srcPort = loadBe16(raw, l4Off)
        let dstPort = loadBe16(raw, l4Off + 2'u32)
        inc nimFwDbgTxTcp
        nimFwDbgTxTcpFlags =
          raw[l4Off + 13'u32].uint32 or
          (srcPort.uint32 shl 8) or
          (dstPort.uint32 shl 24)
        if srcPort == 80'u16 or dstPort == 80'u16:
          inc nimFwDbgTxTcp80
    if isDhcpUdp(eth):
      let ip = ipv4HeaderAt(eth)
      let udp = udpHeaderAt(ip)
      inc nimFwDbgDhcpTx
      nimFwDbgDhcpTxEth = proto.uint32 or (ip.protocol.uint32 shl 16)
      nimFwDbgDhcpTxPorts = udp.srcPort.uint32 or (udp.dstPort.uint32 shl 16)
      nimFwDbgDhcpTxLen = pbuf.totLen.uint32
      nimFwDbgDhcpTxSrcLo = cast[ptr uint32](addr eth.src[0])[]
      nimFwDbgDhcpTxSrcHi = cast[ptr uint16](addr eth.src[4])[].uint32
      let raw = cast[ptr UncheckedArray[uint8]](pbuf.payload)
      let msgType = dhcpMsgTypeFromEthernet(raw, pbuf.len.uint32)
      if msgType != 0'u8:
        discard repairDhcpUdpChecksum(raw, pbuf.len.uint32)
        if msgType == 3'u8:
          nimFwDbgDhcpReqUdpChecksumBefore = nimFwDbgDhcpUdpChecksumBefore
          nimFwDbgDhcpReqUdpChecksumCalc = nimFwDbgDhcpUdpChecksumCalc
          nimFwDbgDhcpReqUdpChecksumAfter = nimFwDbgDhcpUdpChecksumAfter
          nimFwDbgDhcpReqUdpChecksumVerifyBefore = nimFwDbgDhcpUdpChecksumVerifyBefore
          nimFwDbgDhcpReqUdpChecksumVerifyAfter = nimFwDbgDhcpUdpChecksumVerifyAfter
          nimFwDbgDhcpReqUdpChecksumAtCopy =
            udpChecksumFieldFromEthernet(raw, pbuf.len.uint32).uint32
      if msgType < nimFwDbgDhcpTxMsgHist.len.uint8:
        inc nimFwDbgDhcpTxMsgHist[msgType]
      nimFwDbgDhcpTxMsg =
        msgType.uint32 or
        (if pbuf.len.uint32 > 49'u32: loadBe32(raw, 46'u) shl 8 else: 0'u32)
      let rawLimit =
        if pbuf.len.uint32 < nimFwDbgDhcpTxRaw.len.uint32:
          pbuf.len.uint32
        else:
          nimFwDbgDhcpTxRaw.len.uint32
      if msgType == 3'u8 or nimFwDbgDhcpTxRawLen == 0'u32:
        nimFwDbgDhcpTxRawLen =
          if pbuf.totLen.uint32 < rawLimit: pbuf.totLen.uint32 else: rawLimit
        for i in 0 ..< nimFwDbgDhcpTxRawLen.int:
          nimFwDbgDhcpTxRaw[i] = raw[i]
        if msgType == 3'u8:
          nimFwDbgDhcpReqUdpChecksumAtCopy =
            udpChecksumFieldFromEthernet(raw, pbuf.len.uint32).uint32
      if msgType == 3'u8:
        nimFwDbgDhcpRequestTxBreakpoint()
      nimFwDbgDhcpTxBreakpoint()
    if proto == 0x8e88'u16 or proto == 0x888e'u16:
      {.emit: """{ extern volatile unsigned int nimfw_dbg_bl_output_eapol;
                   nimfw_dbg_bl_output_eapol++; }""".}
    nimFwDbgTxStaLookupEth = proto.uint32 or (pbuf.totLen.uint32 shl 16)
    nimFwDbgTxStaLookupDst0 = cast[ptr uint32](addr eth.dst[0])[]
    nimFwDbgTxStaLookupDst1 = cast[ptr uint16](addr eth.dst[4])[].uint32
    let staId = txCntrlGetStaId(isSta, isBcMc(eth.dst[0]),
                                cast[pointer](addr eth.dst[0]))
    if staId < 0:
      {.emit: """{ extern volatile unsigned int nimfw_dbg_bl_output_drop;
                   nimfw_dbg_bl_output_drop++; }""".}
      bl_os_printf("[TX] Cant find valid sta_id, drop! (is_sta: %d, is_bc_mc: %d, proto: %04x)\r\n",
                   isSta, (if isBcMc(eth.dst[0]): 1 else: 0),
                   eth.ethertype.cint)
      return ErrIf

    let sta = staAt(staId)
    if pbuf_header(p, PbufLinkEncapsulationHlen.int16) != 0'u8:
      bl_os_printf("[TX] Reserve room failed for header\r\n")
      return ErrIf

    let payload = pbuf.payload
    let alignOffset = alignPads(payload)
    let linkDescLen = alignOffset + TxHdrSize.uint16 + 16'u16
    if linkDescLen > PbufLinkEncapsulationHlen:
      bl_os_printf("[TX] link_header size is %ld vs header %u\r\n",
                   linkDescLen.cint, PbufLinkEncapsulationHlen.cint)
      return ErrBuf

    let txhdr = bufferAt(payload, alignOffset.uint)
    zero(txhdr, TxHdrSize)
    if customCfm != nil:
      copyMem(cast[pointer](addr txHdrView(txhdr).cfmCb), customCfm, TxCfmSize)
    txHdrView(txhdr).pbuf = p
    setTxHdrLen(txhdr, pbuf.totLen)
    setTxHdrVifType(txhdr, isSta.uint8)
    setTxHdrStaId(txhdr, staId.uint8)

    pbuf_ref(p)
    bl_os_enter_critical()
    listPushBack(cast[pointer](addr staView(sta).waitingList), txhdr)
    txCntrlStaTrigger = txCntrlStaTrigger or bitSta(staId)
    if txCntrlCheckFc(sta):
      bl_irq_handler()
    bl_os_exit_critical()
    ErrOk

  proc bl_tx_cntrl_link_up*(sta: ptr BlSta) {.exportc, cdecl.} =
    txCntrlPurgeCheck(cast[pointer](sta), 1)

  proc bl_tx_cntrl_link_down*(sta: ptr BlSta) {.exportc, cdecl.} =
    txCntrlPurgeCheck(cast[pointer](sta), 0)
