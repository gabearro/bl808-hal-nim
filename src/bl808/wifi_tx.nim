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

    HostdescPbufAddrOff = 0'u
    HostdescPacketAddrOff = 4'u
    HostdescPacketLenOff = 8'u
    HostdescStatusAddrOff = 12'u
    HostdescEthDestOff = 16'u
    HostdescEthSrcOff = 22'u
    HostdescEthertypeOff = 28'u
    HostdescTidOff = 42'u
    HostdescVifIdxOff = 43'u
    HostdescVifTypeOff = 44'u
    HostdescStaIdOff = 45'u
    HostdescFlagsOff = 46'u
    HostdescPbufChainedPtrOff = 48'u
    HostdescPbufChainedLenOff = 64'u
    TxdescHostPadTxdescOff = 12'u
    TxdescUpperHostOff = 4'u
    TxbufHostBufOff = 4'u

    PbufNextOff = 0'u
    PbufPayloadOff = 4'u
    PbufTotLenOff = 8'u
    PbufLenOff = 10'u
    EthDestOff = 0'u
    EthSrcOff = 6'u
    EthTypeOff = 12'u

  type
    BlHw {.importc: "struct bl_hw", header: "bl_defs.h".} = object
    BlSta {.importc: "struct bl_sta", header: "bl_defs.h".} = object
    BlTxCfm {.importc: "struct bl_tx_cfm", header: "bl_tx.h".} = object
    Pbuf {.importc: "struct pbuf", header: "<lwip/pbuf.h>".} = object
    KeTxFc {.importc: "struct ke_tx_fc", header: "bl_tx.h".} = object
    TxCallback = proc(cbArg: pointer; txOk: bool) {.cdecl.}

  {.emit: "extern struct bl_hw wifi_hw;".}
  var wifi_hw {.importc, header: "bl_defs.h".}: BlHw
  var internel_cal_size_tx_hdr* {.exportc.}: cint = TxHdrSize.cint
  var txCntrlStaTrigger: uint32
  var txCntrlStaTriggerPending: uint32

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

  template ptrAt(base: pointer; off: uint): pointer =
    cast[pointer](cast[uint](base) + off)

  proc zero(p: pointer; n: uint) {.inline.} =
    discard c_memset(p, 0, n.csize_t)

  proc copyMem(dest, src: pointer; n: uint) {.inline.} =
    if dest != nil and src != nil and n != 0:
      discard c_memcpy(dest, src, n.csize_t)

  proc loadPtr(base: pointer; off: uint): pointer {.inline.} =
    cast[ptr pointer](ptrAt(base, off))[]

  proc storePtr(base: pointer; off: uint; value: pointer) {.inline.} =
    cast[ptr pointer](ptrAt(base, off))[] = value

  proc loadU8(base: pointer; off: uint): uint8 {.inline.} =
    cast[ptr uint8](ptrAt(base, off))[]

  proc storeU8(base: pointer; off: uint; value: uint8) {.inline.} =
    cast[ptr uint8](ptrAt(base, off))[] = value

  proc loadU16(base: pointer; off: uint): uint16 {.inline.} =
    cast[ptr uint16](ptrAt(base, off))[]

  proc storeU16(base: pointer; off: uint; value: uint16) {.inline.} =
    cast[ptr uint16](ptrAt(base, off))[] = value

  proc loadU32(base: pointer; off: uint): uint32 {.inline.} =
    cast[ptr uint32](ptrAt(base, off))[]

  proc storeU32(base: pointer; off: uint; value: uint32) {.inline.} =
    cast[ptr uint32](ptrAt(base, off))[] = value

  proc listEmpty(list: pointer): bool {.inline.} =
    loadPtr(list, 0) == nil

  proc listPushBack(list, item: pointer) =
    if list == nil or item == nil:
      return
    storePtr(item, 0, nil)
    let last = loadPtr(list, 4)
    if last == nil:
      storePtr(list, 0, item)
    else:
      storePtr(last, 0, item)
    storePtr(list, 4, item)

  proc listPopFront(list: pointer): pointer =
    if list == nil:
      return nil
    result = loadPtr(list, 0)
    if result != nil:
      let next = loadPtr(result, 0)
      storePtr(list, 0, next)
      if next == nil:
        storePtr(list, 4, nil)
      storePtr(result, 0, nil)

  proc alignPads(p: pointer): uint16 {.inline.} =
    ((4'u - (cast[uint](p) and 3'u)) and 3'u).uint16

  proc hwRaw(): pointer {.inline.} = cast[pointer](addr wifi_hw)

  proc vifAt(idx: int): pointer {.inline.} =
    ptrAt(ptrAt(hwRaw(), BlHwVifTableOff), idx.uint * BlVifSize)

  proc staAt(idx: int): pointer {.inline.} =
    ptrAt(ptrAt(hwRaw(), BlHwStaTableOff), idx.uint * BlStaSize)

  proc staVif(sta: pointer): pointer {.inline.} =
    vifAt(loadU8(sta, BlStaVifIdxOff).int)

  proc txHdrLen(txhdr: pointer): uint16 {.inline.} =
    loadU16(txhdr, TxHdrLenOff)

  proc setTxHdrLen(txhdr: pointer; value: uint16) {.inline.} =
    storeU16(txhdr, TxHdrLenOff, value)

  proc txHdrVifType(txhdr: pointer): uint8 {.inline.} =
    loadU8(txhdr, TxHdrVifStaRepushOff) and 0x0f'u8

  proc setTxHdrVifType(txhdr: pointer; value: uint8) {.inline.} =
    storeU8(txhdr, TxHdrVifStaRepushOff,
            (loadU8(txhdr, TxHdrVifStaRepushOff) and 0xf0'u8) or (value and 0x0f'u8))

  proc txHdrStaId(txhdr: pointer): uint8 {.inline.} =
    (loadU8(txhdr, TxHdrVifStaRepushOff) shr 4) and 0x0f'u8

  proc setTxHdrStaId(txhdr: pointer; value: uint8) {.inline.} =
    storeU8(txhdr, TxHdrVifStaRepushOff,
            (loadU8(txhdr, TxHdrVifStaRepushOff) and 0x0f'u8) or ((value and 0x0f'u8) shl 4))

  proc txHdrRepush(txhdr: pointer): uint8 {.inline.} =
    loadU8(txhdr, TxHdrVifStaRepushOff + 1'u)

  proc setTxHdrRepush(txhdr: pointer; value: uint8) {.inline.} =
    storeU8(txhdr, TxHdrVifStaRepushOff + 1'u, value)

  proc bitSta(idx: uint8): uint32 {.inline.} =
    1'u32 shl idx

  proc bitSta(idx: int): uint32 {.inline.} =
    1'u32 shl idx

  proc bitVif(idx: int): uint8 {.inline.} =
    1'u8 shl idx

  proc isBcMc(firstByte: uint8): bool {.inline.} =
    (firstByte and 1'u8) != 0'u8

  proc txCntrlCheckFc(sta: pointer): bool =
    loadU8(sta, BlStaFcPsOff) == 0'u8 and loadU8(staVif(sta), BlVifFcChanOff) == 0'u8

  proc txCntrlUpdateFc(txFcField: pointer): uint32 =
    for i in 0 ..< 2:
      if (loadU8(txFcField, KeTxFcVifBitsOff) and bitVif(i)) != 0'u8:
        if i == BlVifSta:
          let vif = vifAt(BlVifSta)
          let fixedStaIdx = loadU8(vif, BlVifFixedStaIdxOff)
          if loadU8(txFcField, KeTxFcStaFcChanOff) != 0'u8:
            storeU8(vif, BlVifFcChanOff, 0)
          if loadU8(txFcField, KeTxFcStaFcPsOff) != 0'u8:
            storeU8(staAt(fixedStaIdx.int), BlStaFcPsOff, 0)
          result = result or bitSta(fixedStaIdx)
        else:
          let vif = vifAt(BlVifAp)
          let fixedStaIdx = loadU8(vif, BlVifFixedStaIdxOff)
          if loadU8(txFcField, KeTxFcApFcChanOff) != 0'u8:
            storeU8(vif, BlVifFcChanOff, 0)
            result = result or bitSta(fixedStaIdx)
          result = result or loadU8(txFcField, KeTxFcApFcPsStaBitsOff).uint32

  proc txCntrlGetStaId(isSta: int; isBroadcast: bool; macAddr: pointer): int =
    if isSta != 0:
      let vif = vifAt(BlVifSta)
      let apIdx = loadU8(vif, BlVifFixedStaIdxOff)
      let sta = staAt(apIdx.int)
      if loadU8(vif, BlVifLinksNumOff) != 0'u8 and loadU8(sta, BlStaIsUsedOff) != 0'u8:
        return loadU8(sta, BlStaStaIdxOff).int
      return -1

    let apVif = vifAt(BlVifAp)
    if loadU8(apVif, BlVifLinksNumOff) == 0'u8:
      return -1

    let bcmcStaIdx = loadU8(apVif, BlVifFixedStaIdxOff).int
    if isBroadcast:
      let sta = staAt(bcmcStaIdx)
      return if loadU8(sta, BlStaIsUsedOff) != 0'u8: loadU8(sta, BlStaStaIdxOff).int else: -1

    for i in 0 ..< NxRemoteStaStoreMax:
      if i == bcmcStaIdx:
        continue
      let sta = staAt(i)
      if loadU8(sta, BlStaIsUsedOff) != 0'u8 and
          c_memcmp(ptrAt(sta, BlStaAddrOff), macAddr, EthAlen.csize_t) == 0:
        return i
    -1

  proc txCheckRet(isSta, isGroupcast: uint8; value: uint32): int =
    if isSta != 0'u8:
      if (value and FrameSuccessfulTxBit) != 0'u32:
        return 1
    elif (isGroupcast == 0'u8 and (value and FrameSuccessfulTxBit) != 0'u32) or
        (isGroupcast != 0'u8 and (value and DescDoneTxBit) != 0'u32):
      return 1
    0

  proc txCntrlPurgeCheck(sta: pointer; onlyCheck: uint8) =
    if not listEmpty(ptrAt(sta, BlStaPendingListOff)) or not listEmpty(ptrAt(sta, BlStaWaitingListOff)):
      if onlyCheck != 0:
        bl_os_printf("[TX] Have remaining packets when checking!\n\r")
      else:
        bl_os_enter_critical()
        txCntrlStaTrigger = txCntrlStaTrigger or bitSta(loadU8(sta, BlStaStaIdxOff))
        bl_irq_handler()
        bl_os_exit_critical()

  proc txPush(sta, txdescHost, ptxbuf, txhdr: pointer) =
    zero(ptrAt(txdescHost, TxdescHostPadTxdescOff), 208)
    let host = ptrAt(txdescHost, TxdescHostPadTxdescOff + TxdescUpperHostOff)
    let txbuf = ptxbuf
    let txbufBuf = ptrAt(txbuf, TxbufHostBufOff)
    var p: pointer = nil
    var ethhdr: pointer

    if loadPtr(txhdr, TxHdrPbufOff) != txbuf:
      p = loadPtr(txhdr, TxHdrPbufOff)
      ethhdr = ptrAt(loadPtr(p, PbufPayloadOff), PbufLinkEncapsulationHlen.uint)
    else:
      ethhdr = ptrAt(txbufBuf, PbufLinkEncapsulationHlen.uint)

    copyMem(ptrAt(host, HostdescEthDestOff), ptrAt(ethhdr, EthDestOff), EthAlen)
    copyMem(ptrAt(host, HostdescEthSrcOff), ptrAt(ethhdr, EthSrcOff), EthAlen)
    storeU16(host, HostdescEthertypeOff, loadU16(ethhdr, EthTypeOff))
    storeU8(host, HostdescVifTypeOff, txHdrVifType(txhdr))
    storeU16(host, HostdescPacketLenOff, txHdrLen(txhdr) - LinkOffsetLen)
    storeU8(host, HostdescVifIdxOff, loadU8(staVif(sta), BlVifVifIdxOff))
    storeU8(host, HostdescStaIdOff, loadU8(sta, BlStaStaIdxOff))
    storeU8(host, HostdescTidOff, if loadU8(sta, BlStaQosOff) != 0'u8: 0'u8 else: 0xff'u8)
    storeU32(host, HostdescPacketAddrOff, 0x1111_1111'u32)
    storeU16(host, HostdescFlagsOff, 0)

    var newTxhdr = txhdr
    var totalLen: uint16
    if loadPtr(txhdr, TxHdrPbufOff) != txbuf:
      let alignSrc = alignPads(loadPtr(p, PbufPayloadOff))
      let alignDst = alignPads(txbufBuf)
      newTxhdr = ptrAt(txbufBuf, alignDst.uint)
      var q = p
      var loop = 0
      totalLen = 0
      while q != nil:
        let qPayload = loadPtr(q, PbufPayloadOff)
        let qLen = loadU16(q, PbufLenOff)
        if loop == 0:
          copyMem(ptrAt(txbufBuf, PbufLinkEncapsulationHlen.uint),
                  ptrAt(qPayload, PbufLinkEncapsulationHlen.uint),
                  (qLen - PbufLinkEncapsulationHlen).uint)
        else:
          copyMem(ptrAt(txbufBuf, totalLen.uint), qPayload, qLen.uint)
        totalLen = totalLen + qLen
        inc loop
        q = loadPtr(q, PbufNextOff)
      copyMem(newTxhdr, txhdr, TxHdrSize)
      storePtr(newTxhdr, TxHdrPbufOff, txbuf)
      discard pbuf_free(cast[ptr Pbuf](p))
    else:
      totalLen = txHdrLen(newTxhdr)

    storeU32(host, HostdescPbufChainedPtrOff, (cast[uint](txbufBuf) + LinkOffsetLen.uint).uint32)
    storeU32(host, HostdescPbufChainedLenOff, (totalLen - LinkOffsetLen).uint32)
    storeU32(host, HostdescStatusAddrOff, (cast[uint](ptrAt(newTxhdr, TxHdrStatusOff))).uint32)
    storeU32(host, HostdescPbufAddrOff, cast[uint](txbuf).uint32)
    ipc_host_txdesc_push(loadPtr(hwRaw(), BlHwIpcEnvOff), txbuf)

  proc bl_tx_cfm*(pthis, hostId: pointer): cint {.exportc, cdecl.} =
    {.emit: "{ extern volatile unsigned int nimfw_dbg_bl_tx_cfm; nimfw_dbg_bl_tx_cfm++; }".}
    discard pthis
    let buf = ptrAt(hostId, TxbufHostBufOff)
    let txhdr = ptrAt(buf, alignPads(buf).uint)
    let eth = ptrAt(buf, PbufLinkEncapsulationHlen.uint)
    let ethTypeBytes = loadU16(eth, EthTypeOff)
    if ethTypeBytes == 0x8e88'u16 or ethTypeBytes == 0x888e'u16:
      {.emit: "{ extern volatile unsigned int nimfw_dbg_bl_tx_cfm_eapol; nimfw_dbg_bl_tx_cfm_eapol++; }".}
    let value = loadU32(txhdr, TxHdrStatusOff)
    if value == 0'u32:
      bl_os_printf("[TX] FW return status is NULL!!!\n\r")

    let ret = txCheckRet(txHdrVifType(txhdr), if isBcMc(loadU8(eth, EthDestOff)): 1'u8 else: 0'u8, value)
    let sta = staAt(txHdrStaId(txhdr).int)
    let linksNum = loadU8(staVif(sta), BlVifLinksNumOff)

    if ret == 0 and txHdrRepush(txhdr) < 3'u8 and linksNum != 0'u8 and
        loadU8(sta, BlStaIsUsedOff) != 0'u8:
      if (value and RetryLimitReachedBit) != 0'u32:
        txCntrlStaTriggerPending = txCntrlStaTriggerPending or bitSta(loadU8(sta, BlStaStaIdxOff))
      elif (value and FrameRepushableChanBit) != 0'u32:
        storeU8(staVif(sta), BlVifFcChanOff, 1)
      elif (value and FrameRepushablePsBit) != 0'u32:
        storeU8(sta, BlStaFcPsOff, 1)
      else:
        discard
      if ((value and (RetryLimitReachedBit or FrameRepushableChanBit or FrameRepushablePsBit)) != 0'u32):
        setTxHdrRepush(txhdr, txHdrRepush(txhdr) + 1'u8)
        listPushBack(ptrAt(sta, BlStaPendingListOff), txhdr)
        return 0

    let cb = cast[TxCallback](loadPtr(txhdr, TxHdrCustomCfmOff + TxCfmCbOff))
    let cbArg = loadPtr(txhdr, TxHdrCustomCfmOff + TxCfmCbArgOff)
    # For EAPOL frames, record the cb pointer + status code so we can see if
    # MAC HW actually got 802.11 ACK from AP.
    if ethTypeBytes == 0x8e88'u16 or ethTypeBytes == 0x888e'u16:
      {.emit: ["{ extern volatile unsigned int nimfw_dbg_cfm_cb_ptr_last; nimfw_dbg_cfm_cb_ptr_last = (unsigned int)", cb, "; extern volatile unsigned int nimfw_dbg_cfm_last_ethertype; nimfw_dbg_cfm_last_ethertype = (unsigned int)", ethTypeBytes, "; extern volatile unsigned int nimfw_dbg_eapol_cfm_status; nimfw_dbg_eapol_cfm_status = (unsigned int)", value, "; extern volatile unsigned int nimfw_dbg_eapol_cfm_count; nimfw_dbg_eapol_cfm_count++; }"].}
      # ret > 0 means MAC HW reports successful TX (with ACK). ret <= 0 = failure.
      if ret > 0:
        {.emit: "{ extern volatile unsigned int nimfw_dbg_eapol_cfm_ack_ok; nimfw_dbg_eapol_cfm_ack_ok++; }".}
      else:
        {.emit: "{ extern volatile unsigned int nimfw_dbg_eapol_cfm_ack_fail; nimfw_dbg_eapol_cfm_ack_fail++; }".}
    if cb != nil:
      {.emit: "{ extern volatile unsigned int nimfw_dbg_bl_tx_cfm_cb; nimfw_dbg_bl_tx_cfm_cb++; }".}
    ipc_host_txbuf_free(hostId)
    txCntrlStaTriggerPending = txCntrlStaTriggerPending or bitSta(loadU8(sta, BlStaStaIdxOff))
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
      if (staTrigger and bitSta(i)) == 0'u32 or not txCntrlCheckFc(sta):
        continue

      while not listEmpty(ptrAt(sta, BlStaPendingListOff)):
        let txdescHost = ipc_host_txdesc_get(loadPtr(hwRaw(), BlHwIpcEnvOff))
        if txdescHost == nil:
          bl_os_printf("[TX] no more txdesc, wait!\n\r")
          break
        let txhdr = listPopFront(ptrAt(sta, BlStaPendingListOff))
        if txhdr == nil:
          break
        txPush(sta, txdescHost, loadPtr(txhdr, TxHdrPbufOff), txhdr)

      while not listEmpty(ptrAt(sta, BlStaWaitingListOff)):
        let txdescHost = ipc_host_txdesc_get(loadPtr(hwRaw(), BlHwIpcEnvOff))
        if txdescHost == nil:
          {.emit: "{ extern volatile unsigned int nimfw_dbg_tx_nodesc; nimfw_dbg_tx_nodesc++; }".}
          bl_os_printf("[TX] no more txdesc, wait!\n\r")
          break
        let txbuf = ipc_host_txbuf_get(loadPtr(hwRaw(), BlHwIpcEnvOff))
        if txbuf == nil:
          {.emit: "{ extern volatile unsigned int nimfw_dbg_tx_nobuf; nimfw_dbg_tx_nobuf++; }".}
          bl_os_printf("[TX] no more txbuf, wait!\n\r")
          break
        bl_os_enter_critical()
        let txhdr = listPopFront(ptrAt(sta, BlStaWaitingListOff))
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

    let ethhdr = loadPtr(cast[pointer](p), PbufPayloadOff)
    let proto = loadU16(ethhdr, EthTypeOff)
    if proto == 0x8e88'u16 or proto == 0x888e'u16:
      {.emit: """{ extern volatile unsigned int nimfw_dbg_bl_output_eapol;
                   nimfw_dbg_bl_output_eapol++; }""".}
    let staId = txCntrlGetStaId(isSta, isBcMc(loadU8(ethhdr, EthDestOff)),
                                ptrAt(ethhdr, EthDestOff))
    if staId < 0:
      {.emit: """{ extern volatile unsigned int nimfw_dbg_bl_output_drop;
                   nimfw_dbg_bl_output_drop++; }""".}
      bl_os_printf("[TX] Cant find valid sta_id, drop! (is_sta: %d, is_bc_mc: %d, proto: %04x)\r\n",
                   isSta, (if isBcMc(loadU8(ethhdr, EthDestOff)): 1 else: 0),
                   loadU16(ethhdr, EthTypeOff).cint)
      return ErrIf

    let sta = staAt(staId)
    if pbuf_header(p, PbufLinkEncapsulationHlen.int16) != 0'u8:
      bl_os_printf("[TX] Reserve room failed for header\r\n")
      return ErrIf

    let payload = loadPtr(cast[pointer](p), PbufPayloadOff)
    let alignOffset = alignPads(payload)
    let linkDescLen = alignOffset + TxHdrSize.uint16 + 16'u16
    if linkDescLen > PbufLinkEncapsulationHlen:
      bl_os_printf("[TX] link_header size is %ld vs header %u\r\n",
                   linkDescLen.cint, PbufLinkEncapsulationHlen.cint)
      return ErrBuf

    let txhdr = ptrAt(payload, alignOffset.uint)
    zero(txhdr, TxHdrSize)
    if customCfm != nil:
      copyMem(ptrAt(txhdr, TxHdrCustomCfmOff), customCfm, TxCfmSize)
    storePtr(txhdr, TxHdrPbufOff, p)
    setTxHdrLen(txhdr, loadU16(cast[pointer](p), PbufTotLenOff))
    setTxHdrVifType(txhdr, isSta.uint8)
    setTxHdrStaId(txhdr, staId.uint8)

    pbuf_ref(p)
    bl_os_enter_critical()
    listPushBack(ptrAt(sta, BlStaWaitingListOff), txhdr)
    txCntrlStaTrigger = txCntrlStaTrigger or bitSta(staId)
    if txCntrlCheckFc(sta):
      bl_irq_handler()
    bl_os_exit_critical()
    ErrOk

  proc bl_tx_cntrl_link_up*(sta: ptr BlSta) {.exportc, cdecl.} =
    txCntrlPurgeCheck(cast[pointer](sta), 1)

  proc bl_tx_cntrl_link_down*(sta: ptr BlSta) {.exportc, cdecl.} =
    txCntrlPurgeCheck(cast[pointer](sta), 0)
