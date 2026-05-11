## Nim replacement for the BL808 WiFi host utility glue in bl_utils.c.
##
## This removes the SDK utility translation unit from Nim firmware builds. The
## TCP/IP RX upload defaults to the conservative BL808 mempool path: the lower
## layer keeps ownership of WiFi descriptors and buffers. The experimental lwIP
## pbuf delivery path can be enabled with -d:bl808WifiRxPbufInput.

when defined(bl808m0) and defined(bl808WifiVendor) and defined(bl808WifiNimFw):
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
    PbufPool = 0x0282.cint
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
      result = pbuf_alloc(PbufRaw, firstPayloadLen, PbufPool)
      if result == nil:
        return nil
      if pbuf_take(result, firstPayload, firstPayloadLen) != 0'i8:
        discard pbuf_free(result)
        return nil

      for i in 1 ..< WifiPktFragCount:
        let fragLen = loadU16(pkt, WifiPktLenOff + uint(i * 2))
        if fragLen == 0'u16:
          break
        let fragPayload = cast[pointer](loadU32(pkt, WifiPktPktOff + uint(i * 4)).uint)
        let frag = pbuf_alloc(PbufRaw, fragLen, PbufPool)
        if frag == nil:
          discard pbuf_free(result)
          return nil
        if pbuf_take(frag, fragPayload, fragLen) != 0'i8:
          discard pbuf_free(frag)
          discard pbuf_free(result)
          return nil
        pbuf_cat(result, frag)

  {.emit: """
extern void cfg_trace(char *s);
""".}
  proc cfgTrace2(s: cstring) {.importc: "cfg_trace", cdecl.}

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
    when defined(bl808WifiRxPbufInput):
      if (status and RxStatusForward) == 0'u32 or hwhdr == nil:
        return -1

      let flags = loadU32(hwhdr, RxFlagsOff)
      if (flags and RxFlagIs80211Mpdu) != 0'u32:
        return -1

      let staIdx = (flags shr RxFlagStaIdxShift) and RxFlagStaIdxMask
      let vif = rxVif(cast[pointer](addr wifi_hw), staIdx)
      if vif == nil:
        return -1

      let netif = cast[ptr Netif](loadPtr(vif, BlVifDevOff))
      if netif == nil:
        return -1

      let p = allocFramePbuf(msduOffset, pkt)
      if p == nil:
        return -1
      if (extraStatus and BlRxStatusAmsdu) != 0'u32:
        p.flags = p.flags or PbufFlagAmsdu

      if bl808_nim_netif_input_call(p, netif) != 0'i8:
        discard pbuf_free(p)
    else:
      discard status
      discard hwhdr
      discard msduOffset
      discard pkt
      discard extraStatus
    -1
