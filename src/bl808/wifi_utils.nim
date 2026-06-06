## Nim replacement for the BL808 WiFi host utility glue in bl_utils.c.
##
## This removes the SDK utility translation unit from Nim firmware builds. The
## TCP/IP RX upload defaults to the conservative BL808 mempool path: the lower
## layer keeps ownership of WiFi descriptors and buffers. The experimental lwIP
## pbuf delivery path can be enabled with -d:bl808WifiRxPbufInput.

when defined(bl808m0) and defined(bl808WifiNimFw):
  {.passC: "-Ibuild/bl_iot_sdk_b773b3f/components/network/wifi_manager/bl60x_wifi_driver".}
  {.passC: "-Ibuild/bl_iot_sdk_b773b3f/components/network/wifi_manager/bl60x_wifi_driver/include".}

  const
    IpcHostEnvSize = 140'u
    BlCmdMgrLlindOff = 32'u
    BlHwIpcEnvOff = 48'u
    BlHwVifTableOff = 60'u
    BlHwStaTableOff = 100'u
    BlVifSize = 20'u
    BlVifDevOff = 8'u
    BlVifUpOff = 12'u
    BlStaSize = 40'u
    BlStaAddrOff = 16'u
    BlStaIsUsedOff = 22'u
    BlStaVifIdxOff = 24'u
    NxRemoteStaStoreMax = 3
    RxStatusForward = 1'u32
    RxFlagsOff = 48'u
    RxFlagIs80211Mpdu = 1'u32 shl 1
    RxFlagStaIdxShift = 16
    RxFlagStaIdxMask = 0xff'u32
    WifiPktFragCount = 4
    WifiPktPktOff = 0'u
    WifiPktLenOff = 32'u
    PbufRaw = 0.cint
    PbufRam = 0x0280.cint
    PbufFlagAmsdu = 0x80'u8
    BlRxStatusAmsdu = 1'u32

  type
    BlHw {.importc: "struct bl_hw", header: "bl_defs.h".} = object
    IpcSharedEnv {.importc: "struct ipc_shared_env_tag",
                   header: "ipc_shared.h".} = object
    CmdLlindProc = proc(cmdMgr, cmd: pointer): cint {.cdecl.}

  when defined(bl808WifiRxPbufInput):
    type
      ErrT = int8
      Pbuf {.importc: "struct pbuf", header: "<lwip/pbuf.h>".} = object
        next*: ptr Pbuf
        payload*: pointer
        tot_len*: uint16
        len*: uint16
        type_internal* {.importc: "type_internal".}: uint8
        flags*: uint8
      Netif {.importc: "struct netif", header: "<lwip/netif.h>".} = object

  proc c_memset(s: pointer; c: cint; n: csize_t): pointer
    {.importc: "memset", header: "<string.h>", cdecl.}
  proc c_memcpy(dst, src: pointer; n: csize_t): pointer
    {.importc: "memcpy", header: "<string.h>", cdecl.}
  proc c_memcmp(a, b: pointer; n: csize_t): cint
    {.importc: "memcmp", header: "<string.h>", cdecl.}
  proc c_malloc(size: csize_t): pointer
    {.importc: "malloc", header: "<stdlib.h>", cdecl.}
  proc ipc_host_init(env, cb, sharedEnv, pthis: pointer)
    {.importc, cdecl, header: "ipc_host.h".}
  proc bl_cmd_mgr_init(cmdMgr: pointer)
    {.importc, cdecl, header: "bl_cmds.h".}
  proc bl_tx_cfm(pthis, hostid: pointer): cint
    {.importc, cdecl, header: "bl_tx.h".}

  when defined(bl808WifiRxPbufInput):
    proc pbuf_alloc(layer: cint; length: uint16; ptype: cint): ptr Pbuf
      {.importc, cdecl, header: "<lwip/pbuf.h>".}
    proc pbuf_take(p: ptr Pbuf; dataptr: pointer; length: uint16): ErrT
      {.importc, cdecl, header: "<lwip/pbuf.h>".}
    proc pbuf_take_at(p: ptr Pbuf; dataptr: pointer; length, offset: uint16): ErrT
      {.importc, cdecl, header: "<lwip/pbuf.h>".}
    proc pbuf_cat(head, tail: ptr Pbuf)
      {.importc, cdecl, header: "<lwip/pbuf.h>".}
    proc pbuf_free(p: ptr Pbuf): uint8
      {.importc, cdecl, header: "<lwip/pbuf.h>".}

    {.emit: "extern struct bl_hw wifi_hw;".}
    {.emit: """
static err_t bl808_nim_netif_input_call(struct pbuf *p, struct netif *netif)
{
    if (netif == NULL || netif->input == NULL) {
        return (err_t)-1;
    }
    return netif->input(p, netif);
}
""".}
    var wifi_hw {.importc, header: "bl_defs.h".}: BlHw
    proc bl808_nim_netif_input_call(p: ptr Pbuf; netif: ptr Netif): ErrT
      {.importc, cdecl.}

  template ptrAt(base: pointer; off: uint): pointer =
    cast[pointer](cast[uint](base) + off)

  proc loadPtr(base: pointer; off: uint): pointer {.inline.} =
    cast[ptr pointer](ptrAt(base, off))[]

  proc storePtr(base: pointer; off: uint; value: pointer) {.inline.} =
    cast[ptr pointer](ptrAt(base, off))[] = value

  proc loadU8(base: pointer; off: uint): uint8 {.inline.} =
    cast[ptr uint8](ptrAt(base, off))[]

  proc loadU16(base: pointer; off: uint): uint16 {.inline.} =
    cast[ptr uint16](ptrAt(base, off))[]

  proc loadU32(base: pointer; off: uint): uint32 {.inline.} =
    cast[ptr uint32](ptrAt(base, off))[]

  proc bl_radarind*(pthis, hostid: pointer): uint8 {.exportc, cdecl.} =
    discard pthis
    discard hostid
    0

  proc bl_msgackind*(pthis, hostid: pointer): uint8 {.exportc, cdecl.} =
    if pthis != nil:
      let llind = cast[CmdLlindProc](loadPtr(pthis, BlCmdMgrLlindOff))
      if llind != nil:
        discard llind(pthis, hostid)
    0

  proc bl_dbgind*(pthis, hostid: pointer): uint8 {.exportc, cdecl.} =
    discard pthis
    discard hostid
    0

  proc bl_prim_tbtt_ind*(pthis: pointer) {.exportc, cdecl.} =
    discard pthis

  proc bl_sec_tbtt_ind*(pthis: pointer) {.exportc, cdecl.} =
    discard pthis

  proc bl_utils_idx_lookup*(blHw: ptr BlHw; mac: ptr uint8): cint {.exportc, cdecl.} =
    if blHw == nil or mac == nil:
      return -1
    let staTable = ptrAt(cast[pointer](blHw), BlHwStaTableOff)
    for i in 0 ..< NxRemoteStaStoreMax:
      let sta = ptrAt(staTable, uint(i) * BlStaSize)
      if loadU8(sta, BlStaIsUsedOff) != 0'u8 and
          c_memcmp(ptrAt(sta, BlStaAddrOff), mac, 6) == 0:
        return i.cint
    -1

  when defined(bl808WifiRxPbufInput):
    var nimFwDbgTcpipInputMpduConv* {.exportc: "nimfw_dbg_tcpip_input_mpdu_conv".}: uint32
    var nimFwDbgTcpipInputMpduFail* {.exportc: "nimfw_dbg_tcpip_input_mpdu_fail".}: uint32
    var nimFwDbgTcpipInputMpduFailCounts* {.exportc: "nimfw_dbg_tcpip_input_mpdu_fail_counts".}: uint32
    var nimFwDbgTcpipInputMpduFailDetailLo* {.exportc: "nimfw_dbg_tcpip_input_mpdu_fail_detail_lo".}: uint32
    var nimFwDbgTcpipInputMpduFailDetailHi* {.exportc: "nimfw_dbg_tcpip_input_mpdu_fail_detail_hi".}: uint32
    var nimFwDbgTcpipInputMpduLast0* {.exportc: "nimfw_dbg_tcpip_input_mpdu_last0".}: uint32
    var nimFwDbgTcpipInputMpduLast1* {.exportc: "nimfw_dbg_tcpip_input_mpdu_last1".}: uint32
    var nimFwDbgTcpipInputMpduLast2* {.exportc: "nimfw_dbg_tcpip_input_mpdu_last2".}: uint32
    var nimFwDbgTcpipInputEth* {.exportc: "nimfw_dbg_tcpip_input_eth".}: uint32
    var nimFwDbgTcpipInputUdp* {.exportc: "nimfw_dbg_tcpip_input_udp".}: uint32
    var nimFwDbgTcpipInputDhcpRx* {.exportc: "nimfw_dbg_tcpip_input_dhcp_rx".}: uint32
    var nimFwDbgTcpipInputLastPorts* {.exportc: "nimfw_dbg_tcpip_input_last_ports".}: uint32
    var nimFwDbgTcpipInputLastIp* {.exportc: "nimfw_dbg_tcpip_input_last_ip".}: uint32
    var nimFwDbgTcpipInputDhcpMeta* {.exportc: "nimfw_dbg_tcpip_input_dhcp_meta".}: uint32
    var nimFwDbgTcpipInputDhcpXid* {.exportc: "nimfw_dbg_tcpip_input_dhcp_xid".}: uint32
    var nimFwDbgTcpipInputDhcpYiaddr* {.exportc: "nimfw_dbg_tcpip_input_dhcp_yiaddr".}: uint32
    var nimFwDbgTcpipInputDhcpCh0* {.exportc: "nimfw_dbg_tcpip_input_dhcp_ch0".}: uint32
    var nimFwDbgTcpipInputDhcpCh1* {.exportc: "nimfw_dbg_tcpip_input_dhcp_ch1".}: uint32
    var nimFwDbgTcpipInputFrameLast0* {.exportc: "nimfw_dbg_tcpip_input_frame_last0".}: uint32
    var nimFwDbgTcpipInputFrameLast1* {.exportc: "nimfw_dbg_tcpip_input_frame_last1".}: uint32
    var nimFwDbgTcpipInputFrameSrc0* {.exportc: "nimfw_dbg_tcpip_input_frame_src0".}: uint32
    var nimFwDbgTcpipInputFrameSrc1* {.exportc: "nimfw_dbg_tcpip_input_frame_src1".}: uint32
    var nimFwDbgTcpipInputFrameSrc2* {.exportc: "nimfw_dbg_tcpip_input_frame_src2".}: uint32
    var nimFwDbgTcpipInputFrameSrc3* {.exportc: "nimfw_dbg_tcpip_input_frame_src3".}: uint32
    var nimFwDbgTcpipInputFramePbuf0* {.exportc: "nimfw_dbg_tcpip_input_frame_pbuf0".}: uint32
    var nimFwDbgTcpipInputFramePbuf1* {.exportc: "nimfw_dbg_tcpip_input_frame_pbuf1".}: uint32
    var nimFwDbgTcpipInputFramePbuf2* {.exportc: "nimfw_dbg_tcpip_input_frame_pbuf2".}: uint32
    var nimFwDbgTcpipInputFramePbuf3* {.exportc: "nimfw_dbg_tcpip_input_frame_pbuf3".}: uint32
    var nimFwDbgTcpipInputFrameEthType* {.exportc: "nimfw_dbg_tcpip_input_frame_ethertype".}: uint32
    var nimFwDbgTcpipInputArp* {.exportc: "nimfw_dbg_tcpip_input_arp".}: uint32
    var nimFwDbgTcpipInputTcp* {.exportc: "nimfw_dbg_tcpip_input_tcp".}: uint32
    var nimFwDbgTcpipInputTcp80* {.exportc: "nimfw_dbg_tcpip_input_tcp80".}: uint32
    var nimFwDbgTcpipInputTcpFlags* {.exportc: "nimfw_dbg_tcpip_input_tcp_flags".}: uint32
    var nimFwDbgTcpipInputScanHit* {.exportc: "nimfw_dbg_tcpip_input_scan_hit".}: uint32
    var nimFwDbgTcpipInputScanMeta* {.exportc: "nimfw_dbg_tcpip_input_scan_meta".}: uint32
    var nimFwDbgTcpipInputScanPorts* {.exportc: "nimfw_dbg_tcpip_input_scan_ports".}: uint32
    var nimFwDbgTcpipInputScanRaw* {.exportc: "nimfw_dbg_tcpip_input_scan_raw".}: array[96, uint8]
    var nimFwDbgPbufAllocFail {.importc: "nimfw_dbg_pbuf_alloc_fail".}: uint32
    var nimFwDbgPbufTakeFail {.importc: "nimfw_dbg_pbuf_take_fail".}: uint32

    proc macDataHeaderLen(fc: uint16): uint32 {.inline.} =
      result = 24'u32
      if (fc and 0x0300'u16) == 0x0300'u16:
        result += 6
      if (fc and 0x0080'u16) != 0:
        result += 2
      if (fc and 0x4000'u16) != 0:
        result += 8

    proc noteMpduFail(code: uint32) =
      nimFwDbgTcpipInputMpduFail = code
      if code >= 1 and code <= 4:
        nimFwDbgTcpipInputMpduFailDetailLo += 1'u32 shl ((code - 1) * 8)
      elif code >= 5 and code <= 8:
        nimFwDbgTcpipInputMpduFailDetailHi += 1'u32 shl ((code - 5) * 8)
      case code
      of 6:
        nimFwDbgTcpipInputMpduFailCounts += 1
      of 7:
        nimFwDbgTcpipInputMpduFailCounts += 1'u32 shl 8
      of 8:
        nimFwDbgTcpipInputMpduFailCounts += 1'u32 shl 16
      else:
        nimFwDbgTcpipInputMpduFailCounts += 1'u32 shl 24

    proc loadBe16(base: pointer; off: uint): uint16 {.inline.} =
      (loadU8(base, off).uint16 shl 8) or loadU8(base, off + 1).uint16

    proc loadBe32(base: pointer; off: uint): uint32 {.inline.} =
      (loadU8(base, off).uint32 shl 24) or
      (loadU8(base, off + 1).uint32 shl 16) or
      (loadU8(base, off + 2).uint32 shl 8) or
      loadU8(base, off + 3).uint32

    proc loadLe32Bytes(base: pointer; off: uint): uint32 {.inline.} =
      loadU8(base, off).uint32 or
      (loadU8(base, off + 1).uint32 shl 8) or
      (loadU8(base, off + 2).uint32 shl 16) or
      (loadU8(base, off + 3).uint32 shl 24)

    proc dhcpMessageType(eth: pointer; len: uint16): uint8 =
      if len.uint <= 282'u or loadBe32(eth, 278'u) != 0x63825363'u32:
        return 0'u8
      var off = 282'u
      while off + 1 < len.uint:
        let opt = loadU8(eth, off)
        if opt == 0xff'u8:
          break
        if opt == 0'u8:
          inc off
          continue
        let optLen = loadU8(eth, off + 1)
        if off + 2'u + optLen.uint > len.uint:
          break
        if opt == 53'u8 and optLen >= 1'u8:
          return loadU8(eth, off + 2)
        off += 2'u + optLen.uint
      0'u8

    proc noteEthernetInput(p: ptr Pbuf): bool =
      if p == nil or p.payload == nil or p.len < 14'u16:
        return false
      let eth = p.payload
      let etherType = loadBe16(eth, 12)
      nimFwDbgTcpipInputFramePbuf0 = loadLe32Bytes(eth, 0)
      nimFwDbgTcpipInputFramePbuf1 = loadLe32Bytes(eth, 4)
      nimFwDbgTcpipInputFramePbuf2 = loadLe32Bytes(eth, 8)
      nimFwDbgTcpipInputFramePbuf3 = loadLe32Bytes(eth, 12)
      nimFwDbgTcpipInputFrameEthType = etherType.uint32 or (p.len.uint32 shl 16)
      case etherType
      of 0x0800'u16:
        nimFwDbgTcpipInputEth += 1
        result = true
        if p.len >= 34'u16:
          nimFwDbgTcpipInputLastIp =
            loadU8(eth, 26).uint32 or
            (loadU8(eth, 27).uint32 shl 8) or
            (loadU8(eth, 30).uint32 shl 16) or
            (loadU8(eth, 31).uint32 shl 24)
          let ihl = (loadU8(eth, 14) and 0x0F'u8).uint32 * 4'u32
          let l4Off = 14'u32 + ihl
          if ihl >= 20'u32 and l4Off + 4'u32 <= p.len.uint32:
            if loadU8(eth, 23) == 6'u8:
              inc nimFwDbgTcpipInputTcp
              let srcPort = loadBe16(eth, l4Off.uint)
              let dstPort = loadBe16(eth, l4Off.uint + 2'u)
              nimFwDbgTcpipInputLastPorts = srcPort.uint32 or (dstPort.uint32 shl 16)
              if l4Off + 14'u32 < p.len.uint32:
                nimFwDbgTcpipInputTcpFlags =
                  loadU8(eth, l4Off.uint + 13'u).uint32 or
                  (srcPort.uint32 shl 8) or
                  (dstPort.uint32 shl 24)
              if dstPort == 80'u16 or srcPort == 80'u16:
                inc nimFwDbgTcpipInputTcp80
            elif loadU8(eth, 23) == 17'u8 and l4Off + 8'u32 <= p.len.uint32:
              nimFwDbgTcpipInputUdp += 1
              let srcPort = loadBe16(eth, l4Off.uint)
              let dstPort = loadBe16(eth, l4Off.uint + 2'u)
              nimFwDbgTcpipInputLastPorts = srcPort.uint32 or (dstPort.uint32 shl 16)
              if srcPort == 67'u16 and dstPort == 68'u16:
                inc nimFwDbgTcpipInputDhcpRx
                if p.len >= 282'u16:
                  let msgType = dhcpMessageType(eth, p.len)
                  nimFwDbgTcpipInputDhcpMeta =
                    loadU8(eth, 42).uint32 or
                    (loadU8(eth, 44).uint32 shl 8) or
                    (msgType.uint32 shl 16) or
                    (loadBe16(eth, 52).uint32 shl 24)
                  nimFwDbgTcpipInputDhcpXid = loadBe32(eth, 46)
                  nimFwDbgTcpipInputDhcpYiaddr = loadBe32(eth, 58)
                  nimFwDbgTcpipInputDhcpCh0 = loadBe32(eth, 70)
                  nimFwDbgTcpipInputDhcpCh1 = loadBe16(eth, 74).uint32
      of 0x0806'u16:
        inc nimFwDbgTcpipInputArp
        nimFwDbgTcpipInputEth += 1'u32 shl 8
        result = true
      else:
        nimFwDbgTcpipInputEth += 1'u32 shl 16
        result = false

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

    proc rxVif(blHw: pointer; staIdx: uint32): pointer =
      if blHw == nil or staIdx >= NxRemoteStaStoreMax.uint32:
        return nil
      let sta = ptrAt(ptrAt(blHw, BlHwStaTableOff), uint(staIdx) * BlStaSize)
      let vifIdx = loadU8(sta, BlStaVifIdxOff).uint
      if vifIdx >= 2'u:
        return nil
      let vif = ptrAt(ptrAt(blHw, BlHwVifTableOff), vifIdx * BlVifSize)
      if loadU8(vif, BlVifUpOff) == 0'u8:
        return nil
      vif

    proc allocFramePbuf(msduOffset: uint32; pkt: pointer): ptr Pbuf =
      if pkt == nil:
        return nil
      let firstLen = loadU16(pkt, WifiPktLenOff)
      if firstLen.uint32 <= msduOffset:
        return nil
      let firstPayload = cast[pointer](loadU32(pkt, WifiPktPktOff).uint + msduOffset)
      let firstPayloadLen = uint16(firstLen.uint32 - msduOffset)
      nimFwDbgTcpipInputFrameLast1 = firstPayloadLen.uint32 or (firstLen.uint32 shl 16)
      if firstPayloadLen >= 16'u16:
        nimFwDbgTcpipInputFrameSrc0 = loadLe32Bytes(firstPayload, 0)
        nimFwDbgTcpipInputFrameSrc1 = loadLe32Bytes(firstPayload, 4)
        nimFwDbgTcpipInputFrameSrc2 = loadLe32Bytes(firstPayload, 8)
        nimFwDbgTcpipInputFrameSrc3 = loadLe32Bytes(firstPayload, 12)
      result = pbuf_alloc(PbufRaw, firstPayloadLen, PbufRam)
      if result == nil:
        inc nimFwDbgPbufAllocFail
        return nil
      if pbuf_take(result, firstPayload, firstPayloadLen) != 0'i8:
        inc nimFwDbgPbufTakeFail
        discard pbuf_free(result)
        return nil

      for i in 1 ..< WifiPktFragCount:
        let fragLen = loadU16(pkt, WifiPktLenOff + uint(i * 2))
        if fragLen == 0'u16:
          break
        let fragPayload = cast[pointer](loadU32(pkt, WifiPktPktOff + uint(i * 4)).uint)
        let frag = pbuf_alloc(PbufRaw, fragLen, PbufRam)
        if frag == nil:
          inc nimFwDbgPbufAllocFail
          discard pbuf_free(result)
          return nil
        if pbuf_take(frag, fragPayload, fragLen) != 0'i8:
          inc nimFwDbgPbufTakeFail
          discard pbuf_free(frag)
          discard pbuf_free(result)
          return nil
        pbuf_cat(result, frag)

    proc allocMpduEthernetPbuf(msduOffset: uint32; pkt: pointer): ptr Pbuf =
      inc nimFwDbgTcpipInputMpduConv
      if pkt == nil:
        noteMpduFail(1)
        return nil
      let firstLen = loadU16(pkt, WifiPktLenOff).uint32
      nimFwDbgTcpipInputMpduLast0 = firstLen or (msduOffset shl 16)
      if firstLen == 0:
        noteMpduFail(2)
        return nil
      if firstLen <= msduOffset:
        noteMpduFail(3)
        return nil
      let frame = cast[pointer](loadU32(pkt, WifiPktPktOff).uint + msduOffset)
      let frameAvail = firstLen - msduOffset
      if frameAvail < 32:
        noteMpduFail(3)
        return nil

      let fc = loadU16(frame, 0)
      let macLen = macDataHeaderLen(fc)
      nimFwDbgTcpipInputMpduLast1 = fc.uint32 or (macLen shl 16)
      if frameAvail < macLen + 8:
        noteMpduFail(4)
        return nil

      let snap = ptrAt(frame, macLen.uint)
      nimFwDbgTcpipInputMpduLast2 = loadU8(snap, 0).uint32 or
        (loadU8(snap, 1).uint32 shl 8) or
        (loadU8(snap, 2).uint32 shl 16) or
        (loadU8(snap, 3).uint32 shl 24)
      if loadU8(snap, 0) != 0xAA'u8 or loadU8(snap, 1) != 0xAA'u8 or
          loadU8(snap, 2) != 0x03'u8 or loadU8(snap, 3) != 0'u8 or
          loadU8(snap, 4) != 0'u8 or loadU8(snap, 5) != 0'u8:
        noteMpduFail(5)
        return nil

      var ethHdr {.noinit.}: array[14, uint8]
      let toDs = (fc and 0x0100'u16) != 0
      let fromDs = (fc and 0x0200'u16) != 0
      let da =
        if toDs and fromDs: ptrAt(frame, 16)
        elif toDs: ptrAt(frame, 16)
        else: ptrAt(frame, 4)
      let sa =
        if toDs and fromDs: ptrAt(frame, 24)
        elif fromDs: ptrAt(frame, 16)
        else: ptrAt(frame, 10)
      discard c_memcpy(addr ethHdr[0], da, 6.csize_t)
      discard c_memcpy(addr ethHdr[6], sa, 6.csize_t)
      ethHdr[12] = loadU8(snap, 6)
      ethHdr[13] = loadU8(snap, 7)

      let payloadStart = macLen + 8
      let firstPayloadLen = firstLen - payloadStart
      var totalLen = 14'u32 + firstPayloadLen
      for i in 1 ..< WifiPktFragCount:
        let fragLen = loadU16(pkt, WifiPktLenOff + uint(i * 2)).uint32
        if fragLen == 0:
          break
        totalLen += fragLen
      if totalLen > 0xffff'u32:
        noteMpduFail(6)
        return nil

      result = pbuf_alloc(PbufRaw, totalLen.uint16, PbufRam)
      if result == nil:
        inc nimFwDbgPbufAllocFail
        noteMpduFail(6)
        return nil
      if pbuf_take_at(result, addr ethHdr[0], 14'u16, 0'u16) != 0'i8:
        inc nimFwDbgPbufTakeFail
        noteMpduFail(7)
        discard pbuf_free(result)
        return nil

      var pbufOff = 14'u16
      if firstPayloadLen != 0:
        let firstPayload = ptrAt(frame, payloadStart.uint)
        if pbuf_take_at(result, firstPayload, firstPayloadLen.uint16, pbufOff) != 0'i8:
          inc nimFwDbgPbufTakeFail
          noteMpduFail(8)
          discard pbuf_free(result)
          return nil
        pbufOff = uint16(pbufOff.uint32 + firstPayloadLen)
      for i in 1 ..< WifiPktFragCount:
        let fragLen = loadU16(pkt, WifiPktLenOff + uint(i * 2))
        if fragLen == 0'u16:
          break
        let fragPayload = cast[pointer](loadU32(pkt, WifiPktPktOff + uint(i * 4)).uint)
        if pbuf_take_at(result, fragPayload, fragLen, pbufOff) != 0'i8:
          inc nimFwDbgPbufTakeFail
          noteMpduFail(8)
          discard pbuf_free(result)
          return nil
        pbufOff = uint16(pbufOff.uint32 + fragLen.uint32)
      nimFwDbgTcpipInputMpduFail = 0

  {.emit: """
extern void cfg_trace(char *s);
""".}
  proc cfgTrace2(s: cstring) {.importc: "cfg_trace", cdecl.}

  var nimFwDbgTcpipInputCalls* {.exportc: "nimfw_dbg_tcpip_input_calls".}: uint32
  var nimFwDbgTcpipInputNoForward* {.exportc: "nimfw_dbg_tcpip_input_no_forward".}: uint32
  var nimFwDbgTcpipInputMpdu* {.exportc: "nimfw_dbg_tcpip_input_mpdu".}: uint32
  var nimFwDbgTcpipInputNoVif* {.exportc: "nimfw_dbg_tcpip_input_no_vif".}: uint32
  var nimFwDbgTcpipInputNoNetif* {.exportc: "nimfw_dbg_tcpip_input_no_netif".}: uint32
  var nimFwDbgTcpipInputNoPbuf* {.exportc: "nimfw_dbg_tcpip_input_no_pbuf".}: uint32
  var nimFwDbgTcpipInputOk* {.exportc: "nimfw_dbg_tcpip_input_ok".}: uint32
  var nimFwDbgTcpipInputFail* {.exportc: "nimfw_dbg_tcpip_input_fail".}: uint32
  var nimFwDbgTcpipInputNoPbufStatus* {.exportc: "nimfw_dbg_tcpip_input_no_pbuf_status".}: uint32
  var nimFwDbgTcpipInputNoPbufFlags* {.exportc: "nimfw_dbg_tcpip_input_no_pbuf_flags".}: uint32
  var nimFwDbgTcpipInputNoPbufMeta* {.exportc: "nimfw_dbg_tcpip_input_no_pbuf_meta".}: uint32
  var nimFwDbgTcpipInputNoPbufPkt* {.exportc: "nimfw_dbg_tcpip_input_no_pbuf_pkt".}: uint32
  var nimFwDbgTcpipInputNoPbufStage* {.exportc: "nimfw_dbg_tcpip_input_no_pbuf_stage".}: uint32
  var nimFwDbgTcpipInputNoPbufRaw* {.exportc: "nimfw_dbg_tcpip_input_no_pbuf_raw".}: array[64, uint8]

  proc noteTcpipNoPbuf(stage, status, flags, msduOffset: uint32;
                       usedMpduInput: bool; pkt: pointer) =
    inc nimFwDbgTcpipInputNoPbuf
    nimFwDbgTcpipInputNoPbufStage = stage
    nimFwDbgTcpipInputNoPbufStatus = status
    nimFwDbgTcpipInputNoPbufFlags = flags
    nimFwDbgTcpipInputNoPbufMeta =
      (msduOffset and 0xFFFF'u32) or
      ((if usedMpduInput: 1'u32 else: 0'u32) shl 16) or
      (if pkt == nil: 0'u32 else: loadU16(pkt, WifiPktLenOff).uint32 shl 17)
    nimFwDbgTcpipInputNoPbufPkt = cast[uint](pkt).uint32
    for i in 0 ..< nimFwDbgTcpipInputNoPbufRaw.len:
      nimFwDbgTcpipInputNoPbufRaw[i] = 0
    if pkt != nil and loadU16(pkt, WifiPktLenOff) != 0'u16:
      let raw = cast[pointer](loadU32(pkt, WifiPktPktOff).uint)
      let limit =
        if loadU16(pkt, WifiPktLenOff).int < nimFwDbgTcpipInputNoPbufRaw.len:
          loadU16(pkt, WifiPktLenOff).int
        else:
          nimFwDbgTcpipInputNoPbufRaw.len
      for i in 0 ..< limit:
        nimFwDbgTcpipInputNoPbufRaw[i] = loadU8(raw, i.uint)

  proc wifi_nimfw_tcpip_input_calls*(): uint32 {.exportc, cdecl.} =
    nimFwDbgTcpipInputCalls
  proc wifi_nimfw_tcpip_input_ok*(): uint32 {.exportc, cdecl.} =
    nimFwDbgTcpipInputOk
  proc wifi_nimfw_tcpip_input_fail*(): uint32 {.exportc, cdecl.} =
    nimFwDbgTcpipInputFail
  proc wifi_nimfw_tcpip_input_drop_flags*(): uint32 {.exportc, cdecl.} =
    (nimFwDbgTcpipInputNoForward and 0xff'u32) or
      ((nimFwDbgTcpipInputMpdu and 0xff'u32) shl 8) or
      ((nimFwDbgTcpipInputNoVif and 0xff'u32) shl 16) or
      ((nimFwDbgTcpipInputNoNetif and 0xff'u32) shl 24)
  proc wifi_nimfw_tcpip_input_no_pbuf*(): uint32 {.exportc, cdecl.} =
    nimFwDbgTcpipInputNoPbuf

  proc bl_ipc_init*(blHw: ptr BlHw; ipcSharedMem: ptr IpcSharedEnv): cint
      {.exportc, cdecl.} =
    cfgTrace2("[NIMFW] bl_ipc_init entry\r\n")
    if blHw == nil:
      cfgTrace2("[NIMFW] bl_ipc_init blHw=nil\r\n")
      return -1
    if ipcSharedMem == nil:
      cfgTrace2("[NIMFW] bl_ipc_init ipcSharedMem=nil\r\n")
      return -1

    var cb: array[8, pointer]
    cb[0] = cast[pointer](bl_tx_cfm)
    cb[1] = nil
    cb[2] = cast[pointer](bl_radarind)
    cb[3] = nil
    cb[4] = cast[pointer](bl_msgackind)
    cb[5] = cast[pointer](bl_dbgind)
    cb[6] = cast[pointer](bl_prim_tbtt_ind)
    cb[7] = cast[pointer](bl_sec_tbtt_ind)

    let env = c_malloc(IpcHostEnvSize.csize_t)
    if env == nil:
      cfgTrace2("[NIMFW] bl_ipc_init c_malloc=nil\r\n")
      return -1
    cfgTrace2("[NIMFW] bl_ipc_init malloc ok\r\n")
    discard c_memset(env, 0, IpcHostEnvSize.csize_t)
    storePtr(cast[pointer](blHw), BlHwIpcEnvOff, env)
    ipc_host_init(env, addr cb[0], ipcSharedMem, blHw)
    bl_cmd_mgr_init(blHw)
    cfgTrace2("[NIMFW] bl_ipc_init ok\r\n")
    0

  proc bl_utils_dump*() {.exportc, cdecl.} =
    discard

  proc tcpip_stack_input*(swdesc: pointer; status: uint32; hwhdr: pointer;
                          msduOffset: uint32; pkt: pointer;
                          extraStatus: uint32): cint {.exportc, cdecl.} =
    discard swdesc
    inc nimFwDbgTcpipInputCalls
    when defined(bl808WifiRxPbufInput):
      if (status and RxStatusForward) == 0'u32 or hwhdr == nil:
        inc nimFwDbgTcpipInputNoForward
        return -1

      let flags = loadU32(hwhdr, RxFlagsOff)
      noteUploadScan(pkt, msduOffset, flags)
      let staIdx = (flags shr RxFlagStaIdxShift) and RxFlagStaIdxMask
      let vif = rxVif(cast[pointer](addr wifi_hw), staIdx)
      if vif == nil:
        inc nimFwDbgTcpipInputNoVif
        return -1

      let netif = cast[ptr Netif](loadPtr(vif, BlVifDevOff))
      if netif == nil:
        inc nimFwDbgTcpipInputNoNetif
        return -1

      let usedMpduInput = (flags and RxFlagIs80211Mpdu) != 0'u32 and msduOffset == 0'u32
      var p =
        if usedMpduInput:
          allocMpduEthernetPbuf(msduOffset, pkt)
        else:
          let ethOffset =
            if msduOffset >= 14'u32: msduOffset - 14'u32
            else: msduOffset
          let resolvedOffset = ethernetOffsetForUpload(pkt, ethOffset)
          nimFwDbgTcpipInputFrameLast0 = resolvedOffset or (msduOffset shl 16)
          allocFramePbuf(resolvedOffset, pkt)
      if p == nil:
        noteTcpipNoPbuf(1'u32, status, flags, msduOffset, usedMpduInput, pkt)
        return -1
      if (extraStatus and BlRxStatusAmsdu) != 0'u32:
        p.flags = p.flags or PbufFlagAmsdu

      if not noteEthernetInput(p) and
          not usedMpduInput and pkt != nil:
        discard pbuf_free(p)
        let mpduOffset =
          if msduOffset >= 4'u32: msduOffset - 4'u32
          else: 0'u32
        p = allocMpduEthernetPbuf(mpduOffset, pkt)
        if p == nil and mpduOffset != 0'u32:
          p = allocMpduEthernetPbuf(0'u32, pkt)
        if p == nil:
          noteTcpipNoPbuf(2'u32, status, flags, mpduOffset, true, pkt)
          return -1
        discard noteEthernetInput(p)
      if bl808_nim_netif_input_call(p, netif) != 0'i8:
        inc nimFwDbgTcpipInputFail
        discard pbuf_free(p)
        return -1
      else:
        inc nimFwDbgTcpipInputOk
        return 0
    else:
      discard status
      discard hwhdr
      discard msduOffset
      discard pkt
      discard extraStatus
    -1
