# ---------------------------------------------------------------------------
# Primitive types
# ---------------------------------------------------------------------------

type
  KeTaskId* = uint16
  KeMsgId* = uint16

const
  KeMsgConsumed* = 1'i32
  KeMsgSaved* = 2'i32

# ---------------------------------------------------------------------------
# co_list: singly-linked list (next pointer at offset 0)
# ---------------------------------------------------------------------------

type
  CoListNode* {.packed.} = object
    next*: ptr CoListNode

  CoList* {.packed.} = object
    first*: ptr CoListNode
    last*: ptr CoListNode

# ---------------------------------------------------------------------------
# BD address
# ---------------------------------------------------------------------------

type
  BdAddr* {.packed.} = object
    bytes*: array[6, uint8]

  BtbleScanReqPduView* {.packed.} = object
    scanA*: BdAddr
    advA*: BdAddr

  BtbleAdvPduView* {.packed.} = object
    advA*: BdAddr
    advPayload*: array[31, uint8]

# ---------------------------------------------------------------------------
# ke_msg: message header + payload
# Layout from disasm: offset 0 = next (4 bytes, linked list pointer)
#                     offset 4 = id uint16
#                     offset 6 = dest_id uint16
#                     offset 8 = src_id uint16
#                     offset 10 = param_len uint16
#                     offset 12 = param[] variable
# ---------------------------------------------------------------------------

type
  KeMsgHeader* {.packed.} = object
    next*: ptr KeMsgHeader          ## list link (set to -1 when free)
    id*: uint16                     ## message id
    dest_id*: uint16                ## destination task id
    src_id*: uint16                 ## source task id
    param_len*: uint16              ## parameter length

  KeMsgEnvelope* {.packed.} = object
    header*: KeMsgHeader
    param*: UncheckedArray[uint8]

# ---------------------------------------------------------------------------
# ke_timer: timer element
# Layout: offset 0 = next (ptr, list link)
#         offset 4 = id uint16
#         offset 6 = task uint16
#         offset 8 = time (uint32, only lower 23 bits used)
# ---------------------------------------------------------------------------

type
  KeTimer* {.packed.} = object
    next*: ptr KeTimer
    id*: uint16
    task*: uint16
    time*: uint32

# ---------------------------------------------------------------------------
# ke_task: task descriptor
# ---------------------------------------------------------------------------

type
  KeMsgHandler* = proc(msgid: KeMsgId, param: pointer,
                         dest_id: KeTaskId, src_id: KeTaskId): int32 {.cdecl.}

  KeMsgStatusHandler* = proc(msgid: KeMsgId, dest_id: KeTaskId,
                               src_id: KeTaskId): int32 {.cdecl.}

  KeStateMsgHandler* {.packed.} = object
    id*: KeMsgId
    handler*: KeMsgHandler

  KeStateHandler* {.packed.} = object
    msg_table*: ptr KeStateMsgHandler
    msg_cnt*: uint16

  KeTaskDesc* {.packed.} = object
    state_handler*: ptr KeStateHandler
    default_handler*: ptr KeStateHandler
    state*: ptr uint8
    state_max*: uint16
    idx_max*: uint16

# ---------------------------------------------------------------------------
# ke_event: event slot
# ---------------------------------------------------------------------------

type
  KeEventCallback* = proc(evt: uint8) {.cdecl.}

  KeEventSlot* {.packed.} = object
    callback*: KeEventCallback

# ---------------------------------------------------------------------------
# EA (event arbiter) types
# ---------------------------------------------------------------------------

type
  EaEltTag* {.packed.} = object
    node*: CoListNode
    ea_cb_start*: pointer
    ea_cb_stop*: pointer
    ea_cb_cancel*: pointer
    timestamp*: uint32
    asap_limit*: uint32
    duration_min*: uint32
    delay*: uint32
    slot_dur*: uint32
    current_prio*: uint8
    linked*: uint8

  EaIntervalTag* {.packed.} = object
    node*: CoListNode
    interval*: uint32
    offset*: uint32
    bandwidth*: uint32
    link_id*: uint8
    role*: uint8

# ---------------------------------------------------------------------------
# EM buffer descriptors
# ---------------------------------------------------------------------------

type
  EmBufRxDesc* {.packed.} = object
    status*: uint16
    rxDescCtrlPadding*: uint16
    data_len*: uint16
    emBufferOffset*: uint16
    rxDescTailPadding*: array[6, uint8]

  EmBufTxDesc* {.packed.} = object
    status*: uint16
    txDescCtrlPadding*: uint16
    emBufferOffset*: uint16
    data_len*: uint16
    txDescTailPadding*: uint16

  EmBufRxFreeSlot* {.packed.} = object
    status*: uint16
    freeSlotStatusPadding*: array[6, uint8]
    emBufferOffset*: uint16
    freeSlotTailPadding*: array[4, uint8]

  BtbleRxDescView* {.packed.} = object
    status*: uint16
    linkControlPadding*: uint16
    header*: uint16
    timing0*: uint16
    rxClock*: uint16
    timing1*: uint16
    meta*: uint16
    rxMetaPadding*: array[6, uint8]
    dataOffset*: uint16
    rxPayloadTailPadding*: array[10, uint8]

  BtbleConnTxDescView* {.packed.} = object
    status*: uint16
    header*: uint16
    dataOffset*: uint16
    txPayloadTailPadding*: array[10, uint8]

  BtbleConnEventView* {.packed.} = object
    activityType*: uint16
    control*: uint16
    controlPadding*: uint16
    phyControl*: uint16
    accessAddressPrefixPadding*: array[6, uint8]
    accessAddrLow*: uint16
    accessAddrHigh*: uint16
    crcInitLow*: uint16
    crcInitHigh*: uint16
    crcInitPadding*: array[2, uint8]
    channel*: uint16
    rfConfig*: uint16
    eventCountEnable*: uint16
    rxSync*: uint16
    rxSyncPadding*: array[4, uint8]
    txDescPtr*: uint16
    txDescPtrPadding*: array[8, uint8]
    txDuration*: uint16
    rxDuration*: uint16
    channelMap01*: uint16
    channelMap23*: uint16
    channelMapHop*: uint16
    rxTiming*: uint16
    rxTimingPadding*: uint16
    eventCounterPrefixPadding*: array[36, uint8]
    eventCounter*: uint16
    eventCounterAux0*: uint16
    eventCounterAux1*: uint16
    eventCounterAux2*: uint16

  BtbleAccessAddressWordsView* {.packed.} = object
    accessAddrLow*: uint16
    accessAddrHigh*: uint16
    crcInitLow*: uint16
    crcInitHigh*: uint16

  BtbleProgramSlotView* {.packed.} = object
    control*: uint16
    targetLow*: uint16
    targetHigh*: uint16
    fineBackoff*: uint16
    emPtr*: uint16
    duration*: uint16
    rates*: uint16
    tail*: uint16

  SchProgRequestView* {.packed.} = object
    callback*: uint32
    targetTime*: uint32
    fineTime*: uint16
    timingPadding*: array[6, uint8]
    duration*: uint32
    context*: uint32
    primaryType*: uint8
    rate0*: uint8
    rate1*: uint8
    tail*: uint8
    eventIndex*: uint8
    noBackoff*: uint8
    ctrlType*: uint8
    auxControl*: uint8
    hasAux*: uint8
    auxRate*: uint8
    auxRatePadding*: array[2, uint8]

  NimLlcStartEnvView {.packed.} = object
    startEnvPrefixPadding*: array[8, uint8]
    peerFeatureSeed*: array[5, uint8]
    peerFeatureSeedPadding*: uint8
    connIntervalMin*: uint16
    connIntervalMax*: uint16
    connLatency*: uint16
    supervisionTimeout*: uint16
    txPacketTime*: uint16
    txOctets*: uint16
    rxOctets*: uint16
    txRate*: uint8
    rxRate*: uint8
    eventCounter*: uint16
    peerRate*: uint8
    peerRatePadding*: array[3, uint8]
    pendingList*: CoList
    leFeatures*: array[8, uint8]
    controllerFeaturePadding*: array[56, uint8]
    authPayloadTimeout*: uint8
    authPayloadTimeoutPadding*: uint8
    connEventLenMin*: uint16
    connEventLenMax*: uint16
    channelSelection*: uint8
    channelSelectionPadding*: uint8
    maxTxTime*: uint16
    maxRxTime*: uint16
    schedulerWord*: uint32
    minEventSpacing*: uint16
    localSleepClockAccuracy*: uint8
    peerSleepClockAccuracy*: uint8
    flags*: uint16
    flagsTailPadding*: array[10, uint8]

  ConnectIndPayloadView {.packed.} = object
    initiatorAddr*: BdAddr
    advertiserAddr*: BdAddr
    accessAddress*: uint32
    crcInit*: array[3, uint8]
    transmitWindowSize*: uint8
    windowOffset*: uint16
    interval*: uint16
    latency*: uint16
    supervisionTimeout*: uint16
    channelMap*: array[5, uint8]
    hopSca*: uint8

  NimLldConStartParamsView {.packed.} = object
    accessAddress*: uint32
    crcInit*: array[3, uint8]
    transmitWindowSize*: uint8
    windowOffset*: uint16
    interval*: uint16
    latency*: uint16
    supervisionTimeout*: uint16
    channelMap*: array[5, uint8]
    hopIncrement*: uint8
    peerSleepClockAccuracy*: uint8
    sleepClockAccuracyPadding*: uint8
    timingFine*: uint16
    timingFinePadding*: array[2, uint8]
    timingClock*: uint32
    anchorClock*: uint32
    timingSelector*: uint8
    rate*: uint8
    peerRxAddrType*: uint16
    centralRole*: uint8
    centralRolePadding*: array[7, uint8]

  NimLlcControllerDefaultsView {.packed.} = object
    maxTxTime*: uint16
    maxRxTime*: uint16
    minEventSpacing*: uint16
    localSleepClockAccuracy*: uint8
    peerSleepClockAccuracy*: uint8
    authPayloadTimeout*: uint8
    authPayloadTimeoutPadding*: uint8
    connEventLenMin*: uint16
    connEventLenMax*: uint16
    channelSelection*: uint8

  NimLlcStartParamsView {.packed.} = object
    accessAddress*: uint32
    crcInit*: array[3, uint8]
    transmitWindowSize*: uint8
    windowOffset*: uint16
    interval*: uint16
    latency*: uint16
    supervisionTimeout*: uint16
    channelMap*: array[5, uint8]
    hopIncrement*: uint8
    peerSleepClockAccuracy*: uint8
    sleepClockAccuracyPadding*: uint8
    timingFine*: uint16
    timingFinePadding*: uint8
    transmitWindowSizeMirror*: uint8
    timingClock*: uint32
    anchorClock*: uint32
    rate*: uint8
    timingSelector*: uint8
    peerRxAddrType*: uint16
    controllerDefaults*: NimLlcControllerDefaultsView
    controllerDefaultsPadding*: uint8

  NimVendorLlcStartParamsView {.packed.} = object
    accessAddress*: uint32
    crcInit*: array[3, uint8]
    transmitWindowSize*: uint8
    windowOffset*: uint16
    connIntervalMin*: uint16
    connIntervalMax*: uint16
    connLatency*: uint16
    peerFeatureSeed*: array[5, uint8]
    hopSca*: uint8
    peerRate*: uint8
    peerRatePadding*: uint8
    timingFine*: uint16
    timingFinePadding*: uint8
    transmitWindowSizeMirror*: uint8
    timingClock*: uint32
    anchorClock*: uint32
    phyRate*: uint8
    directAnchorMode*: uint8
    peerRxAddrType*: uint16
    controllerDefaults*: NimLlcControllerDefaultsView
    controllerDefaultsPadding*: uint8

  LlmAdvertiserConnView {.packed.} = object
    advertiserConnPrefixPadding*: array[24, uint8]
    intervalMinSlots*: uint16
    intervalMaxSlots*: uint16
    intervalLatencyWord*: uint32
    supervisionMinSlots*: uint16
    supervisionMaxSlots*: uint16
    driftSlots*: uint16
    driftSlotsPadding*: array[2, uint8]
    peerAddr*: BdAddr
    peerAddrType*: uint8
    connected*: uint8
    connectionStatePadding*: array[24, uint8]
    state*: uint8

  NimLldAdvParamsView {.packed.} = object
    advA*: BdAddr
    initA*: BdAddr
    addrPairPadding*: array[4, uint8]
    advDataPtr*: uint16
    advDataPtrPadding*: array[2, uint8]
    advDataLen*: uint16
    advDataLenPadding*: array[2, uint8]
    advType*: uint8
    advTypePadding*: array[4, uint8]
    channelMap*: uint8
    channelMapPadding*: array[3, uint8]
    txPower*: uint8
    primaryPhy*: uint8
    secondaryMaxSkip*: uint8
    secondaryPhy*: uint8
    secondaryPhyPadding*: array[3, uint8]

  NimLldScanParamsView {.packed.} = object
    localAddr*: BdAddr
    addrType*: uint8
    flags*: uint8
    intervalMin*: uint16
    intervalMax*: uint16
    windowMin*: uint16
    windowMax*: uint16
    scanType*: uint8
    scanTypeMirror*: uint8
    filterPolicy*: uint8
    filterPolicyPadding*: array[3, uint8]
    duration*: uint16
    schedulerOverlay*: array[104, uint8]

  NimLldInitParamsView {.packed.} = object
    localAddr*: BdAddr
    peerAddr*: BdAddr
    channelMap*: array[5, uint8]
    channelMapPadding*: uint8
    phyMask*: uint8
    activityId*: uint8
    ownAddrType*: uint8
    peerAddrType*: uint8
    filterPolicy*: uint8
    filterPolicyPadding*: uint8
    scanInterval*: uint16
    scanWindow*: uint16
    connInterval*: uint16
    connOffset*: uint16
    connLatency*: uint16
    supervisionTimeout*: uint16
    minCeLen*: uint16
    maxCeLen*: uint16
    controllerOverlay*: array[28, uint8]

  EmBufNode* {.packed.} = object
    next*: ptr EmBufNode
    poolSlotIndex*: uint16
    emBufferOffset*: uint16

static:
  doAssert sizeof(KeMsgHeader) == 12
  doAssert offsetof(KeMsgHeader, id) == 4
  doAssert offsetof(KeMsgHeader, dest_id) == 6
  doAssert offsetof(KeMsgHeader, src_id) == 8
  doAssert offsetof(KeMsgHeader, param_len) == 10
  doAssert offsetof(KeMsgEnvelope, header) == 0
  doAssert offsetof(KeMsgEnvelope, param) == sizeof(KeMsgHeader)
  doAssert sizeof(EmBufRxDesc) == EM_BUF_RX_DESC_SIZE
  doAssert offsetof(EmBufRxDesc, status) == 0
  doAssert offsetof(EmBufRxDesc, data_len) == 4
  doAssert offsetof(EmBufRxDesc, emBufferOffset) == 6
  doAssert sizeof(EmBufTxDesc) == EM_BUF_TX_DESC_SIZE
  doAssert offsetof(EmBufTxDesc, status) == 0
  doAssert offsetof(EmBufTxDesc, emBufferOffset) == 4
  doAssert offsetof(EmBufTxDesc, data_len) == 6
  doAssert sizeof(EmBufRxFreeSlot) == EM_BUF_RX_DESC_SIZE
  doAssert offsetof(EmBufRxFreeSlot, status) == 0
  doAssert offsetof(EmBufRxFreeSlot, emBufferOffset) == 8
  doAssert sizeof(EmBufNode) == 8
  doAssert offsetof(EmBufNode, next) == 0
  doAssert offsetof(EmBufNode, poolSlotIndex) == 4
  doAssert offsetof(EmBufNode, emBufferOffset) == 6
  doAssert sizeof(BtbleScanReqPduView) == 12
  doAssert offsetof(BtbleScanReqPduView, scanA) == 0
  doAssert offsetof(BtbleScanReqPduView, advA) == 6
  doAssert offsetof(BtbleAdvPduView, advA) == 0
  doAssert offsetof(BtbleAdvPduView, advPayload) == 6
  doAssert sizeof(BtbleRxDescView) == 0x20
  doAssert offsetof(BtbleRxDescView, status) == 0
  doAssert offsetof(BtbleRxDescView, linkControlPadding) == 0x02
  doAssert offsetof(BtbleRxDescView, header) == 0x04
  doAssert offsetof(BtbleRxDescView, rxClock) == 0x08
  doAssert offsetof(BtbleRxDescView, meta) == 0x0C
  doAssert offsetof(BtbleRxDescView, dataOffset) == 0x14
  doAssert sizeof(BtbleConnTxDescView) == 0x10
  doAssert offsetof(BtbleConnTxDescView, status) == 0
  doAssert offsetof(BtbleConnTxDescView, header) == 0x02
  doAssert offsetof(BtbleConnTxDescView, dataOffset) == 0x04
  doAssert sizeof(BtbleConnEventView) == 0x68
  doAssert offsetof(BtbleConnEventView, activityType) == 0
  doAssert offsetof(BtbleConnEventView, controlPadding) == 0x04
  doAssert offsetof(BtbleConnEventView, phyControl) == 0x06
  doAssert offsetof(BtbleConnEventView, accessAddressPrefixPadding) == 0x08
  doAssert offsetof(BtbleConnEventView, accessAddrLow) == 0x0E
  doAssert offsetof(BtbleConnEventView, crcInitPadding) == 0x16
  doAssert offsetof(BtbleConnEventView, channel) == 0x18
  doAssert offsetof(BtbleConnEventView, rxSync) == 0x1E
  doAssert offsetof(BtbleConnEventView, rxSyncPadding) == 0x20
  doAssert offsetof(BtbleConnEventView, txDescPtr) == 0x24
  doAssert offsetof(BtbleConnEventView, txDescPtrPadding) == 0x26
  doAssert offsetof(BtbleConnEventView, txDuration) == 0x2E
  doAssert offsetof(BtbleConnEventView, channelMap01) == 0x32
  doAssert offsetof(BtbleConnEventView, rxTiming) == 0x38
  doAssert offsetof(BtbleConnEventView, rxTimingPadding) == 0x3A
  doAssert offsetof(BtbleConnEventView, eventCounterPrefixPadding) == 0x3C
  doAssert offsetof(BtbleConnEventView, eventCounter) == 0x60
  doAssert sizeof(BtbleAccessAddressWordsView) == 0x08
  doAssert offsetof(BtbleAccessAddressWordsView, accessAddrLow) == 0
  doAssert offsetof(BtbleAccessAddressWordsView, accessAddrHigh) == 0x02
  doAssert offsetof(BtbleAccessAddressWordsView, crcInitLow) == 0x04
  doAssert offsetof(BtbleAccessAddressWordsView, crcInitHigh) == 0x06
  doAssert sizeof(BtbleProgramSlotView) == 0x10
  doAssert offsetof(BtbleProgramSlotView, control) == 0
  doAssert offsetof(BtbleProgramSlotView, targetLow) == 0x02
  doAssert offsetof(BtbleProgramSlotView, targetHigh) == 0x04
  doAssert offsetof(BtbleProgramSlotView, fineBackoff) == 0x06
  doAssert offsetof(BtbleProgramSlotView, emPtr) == 0x08
  doAssert offsetof(BtbleProgramSlotView, duration) == 0x0A
  doAssert offsetof(BtbleProgramSlotView, rates) == 0x0C
  doAssert offsetof(BtbleProgramSlotView, tail) == 0x0E
  doAssert sizeof(SchProgRequestView) == 36
  doAssert offsetof(SchProgRequestView, targetTime) == 0x04
  doAssert offsetof(SchProgRequestView, fineTime) == 0x08
  doAssert offsetof(SchProgRequestView, timingPadding) == 0x0A
  doAssert offsetof(SchProgRequestView, duration) == 0x10
  doAssert offsetof(SchProgRequestView, context) == 0x14
  doAssert offsetof(SchProgRequestView, primaryType) == 0x18
  doAssert offsetof(SchProgRequestView, eventIndex) == 0x1C
  doAssert offsetof(SchProgRequestView, hasAux) == 0x20
  doAssert offsetof(SchProgRequestView, auxRatePadding) == 0x22
  doAssert sizeof(NimLlcStartEnvView) == 0x8C
  doAssert offsetof(NimLlcStartEnvView, startEnvPrefixPadding) == 0
  doAssert offsetof(NimLlcStartEnvView, peerFeatureSeed) == 8
  doAssert offsetof(NimLlcStartEnvView, peerFeatureSeedPadding) == 13
  doAssert offsetof(NimLlcStartEnvView, peerRatePadding) == 33
  doAssert offsetof(NimLlcStartEnvView, pendingList) == 36
  doAssert offsetof(NimLlcStartEnvView, leFeatures) == 44
  doAssert offsetof(NimLlcStartEnvView, controllerFeaturePadding) == 52
  doAssert offsetof(NimLlcStartEnvView, authPayloadTimeout) == 108
  doAssert offsetof(NimLlcStartEnvView, authPayloadTimeoutPadding) == 109
  doAssert offsetof(NimLlcStartEnvView, connEventLenMin) == 110
  doAssert offsetof(NimLlcStartEnvView, channelSelectionPadding) == 115
  doAssert offsetof(NimLlcStartEnvView, schedulerWord) == 120
  doAssert offsetof(NimLlcStartEnvView, flags) == 128
  doAssert offsetof(NimLlcStartEnvView, flagsTailPadding) == 130
  doAssert sizeof(ConnectIndPayloadView) == 34
  doAssert offsetof(ConnectIndPayloadView, accessAddress) == 12
  doAssert offsetof(ConnectIndPayloadView, crcInit) == 16
  doAssert offsetof(ConnectIndPayloadView, transmitWindowSize) == 19
  doAssert offsetof(ConnectIndPayloadView, channelMap) == 28
  doAssert sizeof(NimLldConStartParamsView) == 48
  doAssert offsetof(NimLldConStartParamsView, crcInit) == 4
  doAssert offsetof(NimLldConStartParamsView, windowOffset) == 8
  doAssert offsetof(NimLldConStartParamsView, channelMap) == 16
  doAssert offsetof(NimLldConStartParamsView, sleepClockAccuracyPadding) == 23
  doAssert offsetof(NimLldConStartParamsView, timingFine) == 24
  doAssert offsetof(NimLldConStartParamsView, timingFinePadding) == 26
  doAssert offsetof(NimLldConStartParamsView, timingClock) == 28
  doAssert offsetof(NimLldConStartParamsView, timingSelector) == 36
  doAssert offsetof(NimLldConStartParamsView, peerRxAddrType) == 38
  doAssert offsetof(NimLldConStartParamsView, centralRole) == 40
  doAssert offsetof(NimLldConStartParamsView, centralRolePadding) == 41
  doAssert sizeof(NimLlcControllerDefaultsView) == 15
  doAssert offsetof(NimLlcControllerDefaultsView, maxRxTime) == 2
  doAssert offsetof(NimLlcControllerDefaultsView, authPayloadTimeout) == 8
  doAssert offsetof(NimLlcControllerDefaultsView, authPayloadTimeoutPadding) == 9
  doAssert offsetof(NimLlcControllerDefaultsView, channelSelection) == 14
  doAssert sizeof(NimLlcStartParamsView) == 56
  doAssert offsetof(NimLlcStartParamsView, sleepClockAccuracyPadding) == 23
  doAssert offsetof(NimLlcStartParamsView, timingFinePadding) == 26
  doAssert offsetof(NimLlcStartParamsView, transmitWindowSizeMirror) == 27
  doAssert offsetof(NimLlcStartParamsView, rate) == 36
  doAssert offsetof(NimLlcStartParamsView, timingSelector) == 37
  doAssert offsetof(NimLlcStartParamsView, controllerDefaults) == 40
  doAssert offsetof(NimLlcStartParamsView, controllerDefaultsPadding) == 55
  doAssert sizeof(NimVendorLlcStartParamsView) == 56
  doAssert offsetof(NimVendorLlcStartParamsView, connIntervalMin) == 10
  doAssert offsetof(NimVendorLlcStartParamsView, connIntervalMax) == 12
  doAssert offsetof(NimVendorLlcStartParamsView, connLatency) == 14
  doAssert offsetof(NimVendorLlcStartParamsView, peerFeatureSeed) == 16
  doAssert offsetof(NimVendorLlcStartParamsView, peerRate) == 22
  doAssert offsetof(NimVendorLlcStartParamsView, peerRatePadding) == 23
  doAssert offsetof(NimVendorLlcStartParamsView, timingFine) == 24
  doAssert offsetof(NimVendorLlcStartParamsView, timingFinePadding) == 26
  doAssert offsetof(NimVendorLlcStartParamsView, timingClock) == 28
  doAssert offsetof(NimVendorLlcStartParamsView, anchorClock) == 32
  doAssert offsetof(NimVendorLlcStartParamsView, phyRate) == 36
  doAssert offsetof(NimVendorLlcStartParamsView, directAnchorMode) == 37
  doAssert offsetof(NimVendorLlcStartParamsView, peerRxAddrType) == 38
  doAssert offsetof(NimVendorLlcStartParamsView, controllerDefaults) == 40
  doAssert offsetof(NimVendorLlcStartParamsView, controllerDefaultsPadding) == 55
  doAssert offsetof(LlmAdvertiserConnView, intervalMinSlots) == 24
  doAssert offsetof(LlmAdvertiserConnView, advertiserConnPrefixPadding) == 0
  doAssert offsetof(LlmAdvertiserConnView, peerAddr) == 40
  doAssert offsetof(LlmAdvertiserConnView, driftSlotsPadding) == 38
  doAssert offsetof(LlmAdvertiserConnView, connectionStatePadding) == 48
  doAssert offsetof(LlmAdvertiserConnView, state) == 72
  doAssert sizeof(NimLldAdvParamsView) == 40
  doAssert offsetof(NimLldAdvParamsView, advDataPtr) == 16
  doAssert offsetof(NimLldAdvParamsView, advDataPtrPadding) == 18
  doAssert offsetof(NimLldAdvParamsView, advDataLen) == 20
  doAssert offsetof(NimLldAdvParamsView, advDataLenPadding) == 22
  doAssert offsetof(NimLldAdvParamsView, advType) == 24
  doAssert offsetof(NimLldAdvParamsView, advTypePadding) == 25
  doAssert offsetof(NimLldAdvParamsView, channelMap) == 29
  doAssert offsetof(NimLldAdvParamsView, channelMapPadding) == 30
  doAssert offsetof(NimLldAdvParamsView, txPower) == 33
  doAssert offsetof(NimLldAdvParamsView, primaryPhy) == 34
  doAssert offsetof(NimLldAdvParamsView, secondaryPhy) == 36
  doAssert offsetof(NimLldAdvParamsView, secondaryPhyPadding) == 37
  doAssert sizeof(NimLldScanParamsView) == 128
  doAssert offsetof(NimLldScanParamsView, addrType) == 6
  doAssert offsetof(NimLldScanParamsView, flags) == 7
  doAssert offsetof(NimLldScanParamsView, intervalMin) == 8
  doAssert offsetof(NimLldScanParamsView, windowMax) == 14
  doAssert offsetof(NimLldScanParamsView, filterPolicy) == 18
  doAssert offsetof(NimLldScanParamsView, filterPolicyPadding) == 19
  doAssert offsetof(NimLldScanParamsView, duration) == 22
  doAssert sizeof(NimLldInitParamsView) == 68
  doAssert offsetof(NimLldInitParamsView, channelMap) == 12
  doAssert offsetof(NimLldInitParamsView, channelMapPadding) == 17
  doAssert offsetof(NimLldInitParamsView, phyMask) == 18
  doAssert offsetof(NimLldInitParamsView, activityId) == 19
  doAssert offsetof(NimLldInitParamsView, ownAddrType) == 20
  doAssert offsetof(NimLldInitParamsView, peerAddrType) == 21
  doAssert offsetof(NimLldInitParamsView, filterPolicy) == 22
  doAssert offsetof(NimLldInitParamsView, filterPolicyPadding) == 23
  doAssert offsetof(NimLldInitParamsView, scanInterval) == 24
  doAssert offsetof(NimLldInitParamsView, connInterval) == 28
  doAssert offsetof(NimLldInitParamsView, connOffset) == 30
  doAssert offsetof(NimLldInitParamsView, connLatency) == 32
  doAssert offsetof(NimLldInitParamsView, supervisionTimeout) == 34
  doAssert offsetof(NimLldInitParamsView, minCeLen) == 36
  doAssert offsetof(NimLldInitParamsView, maxCeLen) == 38
# ---------------------------------------------------------------------------
# HCI types
# ---------------------------------------------------------------------------

type
  HciCmdDescTag* {.packed.} = object
    opcode*: uint16
    param_len*: uint8
    dest_id*: uint8

  HciEvtDescTag* {.packed.} = object
    code*: uint8
    param_len*: uint8

  HciFlowControl* {.packed.} = object
    acl_pkt_nb*: uint16
    acl_buf_size*: uint16
    flow_en*: bool

  OnChipHciRecvCb* = proc(pktType: uint8, srcId: uint16,
                           param: ptr uint8, paramLen: uint8) {.cdecl.}

  OnChipHciCmd* = object
    opcode*: uint16
    params*: ptr uint8
    paramLen*: uint8

  OnChipHciAclDataTx* = object
    conhdl*: uint16
    pbBcFlag*: uint8
    len*: uint16
    buffer*: ptr uint8

  HciRawCommandPacket* {.packed.} = object
    opcode*: uint16
    paramLen*: uint8
    params*: array[1, uint8]

  HciCmdStatusDescView {.packed.} = object
    statusDescriptorPrefixPadding*: array[8, uint8]
    expectedStatusWord*: uint32

  HciRawCmdView {.packed.} = object
    opcode*: uint16
    paramLen*: uint8
    params*: UncheckedArray[uint8]

  HciEventRoutingView {.packed.} = object
    eventCode*: uint8
    route*: uint8
    hostLid*: uint8

  HciAclHostPacketView {.packed.} = object
    handleFlags*: uint16
    length*: uint16
    payload*: UncheckedArray[uint8]

  HciDisconnectCompleteEventView {.packed.} = object
    status*: uint8
    handle*: uint16
    reason*: uint8

  HciEncryptionChangeEventView {.packed.} = object
    status*: uint8
    handle*: uint16
    enabled*: uint8

  HciRemoteVersionInfoCompleteEventView {.packed.} = object
    status*: uint8
    handle*: uint16
    version*: uint8
    companyId*: uint16
    subversion*: uint16

  HciLeConnectionCompleteEventView {.packed.} = object
    subevent*: uint8
    status*: uint8
    handle*: uint16
    role*: uint8
    peerAddrType*: uint8
    peerAddr*: BdAddr
    interval*: uint16
    latency*: uint16
    timeout*: uint16
    accuracy*: uint8

  HciLeConnectionUpdateCompleteEventView {.packed.} = object
    subevent*: uint8
    status*: uint8
    handle*: uint16
    interval*: uint16
    latency*: uint16
    timeout*: uint16

  HciLeRemoteFeaturesCompleteEventView {.packed.} = object
    subevent*: uint8
    status*: uint8
    handle*: uint16
    features*: array[8, uint8]

  HciLePhyUpdateCompleteEventView {.packed.} = object
    subevent*: uint8
    status*: uint8
    handle*: uint16
    txPhy*: uint8
    rxPhy*: uint8

  HciAclDataIndView {.packed.} = object
    handleFlags*: uint16
    length*: uint16
    dataAddr*: uint32

  LldAclRxIndView {.packed.} = object
    bufRef*: uint16
    length*: uint16
    llidFlags*: uint8

  HciLeCreateConnReqView* {.packed.} = object
    scanInterval*: uint16
    scanWindow*: uint16
    filterPolicy*: uint8
    peerAddrType*: uint8
    peerAddr*: BdAddr
    ownAddrType*: uint8
    connIntervalMin*: uint16
    connIntervalMax*: uint16
    connLatency*: uint16
    supervisionTimeout*: uint16
    minCeLen*: uint16
    maxCeLen*: uint16

  HciLeConnUpdateReqView* {.packed.} = object
    handle*: uint16
    connIntervalMin*: uint16
    connIntervalMax*: uint16
    connLatency*: uint16
    supervisionTimeout*: uint16
    minCeLen*: uint16
    maxCeLen*: uint16

  HciLeSetPhyReqView* {.packed.} = object
    handle*: uint16
    allPhys*: uint8
    txPhys*: uint8
    rxPhys*: uint8
    phyOptions*: uint16

  HciLeSetDataLenReqView* {.packed.} = object
    handle*: uint16
    txOctets*: uint16
    txTime*: uint16

  HciLeSuggestedDataLenReqView* {.packed.} = object
    txOctets*: uint16
    txTime*: uint16

  HciLeSetAdvSetRandomAddressReqView* {.packed.} = object
    advertisingHandle*: uint8
    randomAddress*: BdAddr

  HciConnHandleReqView* {.packed.} = object
    handle*: uint16

  HciDisconnectReqView* {.packed.} = object
    handle*: uint16
    reason*: uint8

  HciLeSetRandomAddressReqView* {.packed.} = object
    address*: BdAddr

  HciLeSetAdvParamsReqView* {.packed.} = object
    encodedParams*: array[15, uint8]

  HciLeDataPayloadReqView* {.packed.} = object
    length*: uint8
    payload*: array[31, uint8]

  HciLeSetAdvEnableReqView* {.packed.} = object
    enabled*: uint8

  HciLeSetScanParamsReqView* {.packed.} = object
    scanType*: uint8
    interval*: uint16
    window*: uint16
    ownAddrType*: uint8
    filterPolicy*: uint8

  HciLeSetScanEnableReqView* {.packed.} = object
    enabled*: uint8
    filterDuplicates*: uint8

  HciWriteAuthPayloadTimeoutReqView* {.packed.} = object
    handle*: uint16
    timeout*: uint16

static:
  doAssert sizeof(HciRawCommandPacket) == 4
  doAssert offsetof(HciRawCommandPacket, opcode) == 0
  doAssert offsetof(HciRawCommandPacket, paramLen) == 2
  doAssert offsetof(HciRawCommandPacket, params) == 3
  doAssert sizeof(HciCmdStatusDescView) == 12
  doAssert offsetof(HciCmdStatusDescView, statusDescriptorPrefixPadding) == 0
  doAssert offsetof(HciCmdStatusDescView, expectedStatusWord) == 8
  doAssert offsetof(HciRawCmdView, opcode) == 0
  doAssert offsetof(HciRawCmdView, paramLen) == 2
  doAssert offsetof(HciRawCmdView, params) == 3
  doAssert sizeof(HciEventRoutingView) == 3
  doAssert offsetof(HciEventRoutingView, route) == 1
  doAssert offsetof(HciEventRoutingView, hostLid) == 2
  doAssert offsetof(HciAclHostPacketView, handleFlags) == 0
  doAssert offsetof(HciAclHostPacketView, length) == 2
  doAssert offsetof(HciAclHostPacketView, payload) == 4
  doAssert sizeof(HciDisconnectCompleteEventView) == 4
  doAssert offsetof(HciDisconnectCompleteEventView, handle) == 1
  doAssert offsetof(HciDisconnectCompleteEventView, reason) == 3
  doAssert sizeof(HciEncryptionChangeEventView) == 4
  doAssert offsetof(HciEncryptionChangeEventView, handle) == 1
  doAssert offsetof(HciEncryptionChangeEventView, enabled) == 3
  doAssert sizeof(HciRemoteVersionInfoCompleteEventView) == 8
  doAssert offsetof(HciRemoteVersionInfoCompleteEventView, handle) == 1
  doAssert offsetof(HciRemoteVersionInfoCompleteEventView, version) == 3
  doAssert offsetof(HciRemoteVersionInfoCompleteEventView, companyId) == 4
  doAssert offsetof(HciRemoteVersionInfoCompleteEventView, subversion) == 6
  doAssert sizeof(HciLeConnectionCompleteEventView) == 19
  doAssert offsetof(HciLeConnectionCompleteEventView, status) == 1
  doAssert offsetof(HciLeConnectionCompleteEventView, handle) == 2
  doAssert offsetof(HciLeConnectionCompleteEventView, role) == 4
  doAssert offsetof(HciLeConnectionCompleteEventView, peerAddrType) == 5
  doAssert offsetof(HciLeConnectionCompleteEventView, peerAddr) == 6
  doAssert offsetof(HciLeConnectionCompleteEventView, interval) == 12
  doAssert offsetof(HciLeConnectionCompleteEventView, latency) == 14
  doAssert offsetof(HciLeConnectionCompleteEventView, timeout) == 16
  doAssert offsetof(HciLeConnectionCompleteEventView, accuracy) == 18
  doAssert sizeof(HciLeConnectionUpdateCompleteEventView) == 10
  doAssert offsetof(HciLeConnectionUpdateCompleteEventView, status) == 1
  doAssert offsetof(HciLeConnectionUpdateCompleteEventView, handle) == 2
  doAssert offsetof(HciLeConnectionUpdateCompleteEventView, interval) == 4
  doAssert offsetof(HciLeConnectionUpdateCompleteEventView, latency) == 6
  doAssert offsetof(HciLeConnectionUpdateCompleteEventView, timeout) == 8
  doAssert sizeof(HciLeRemoteFeaturesCompleteEventView) == 12
  doAssert offsetof(HciLeRemoteFeaturesCompleteEventView, status) == 1
  doAssert offsetof(HciLeRemoteFeaturesCompleteEventView, handle) == 2
  doAssert offsetof(HciLeRemoteFeaturesCompleteEventView, features) == 4
  doAssert sizeof(HciLePhyUpdateCompleteEventView) == 6
  doAssert offsetof(HciLePhyUpdateCompleteEventView, status) == 1
  doAssert offsetof(HciLePhyUpdateCompleteEventView, handle) == 2
  doAssert offsetof(HciLePhyUpdateCompleteEventView, txPhy) == 4
  doAssert offsetof(HciLePhyUpdateCompleteEventView, rxPhy) == 5
  doAssert sizeof(HciAclDataIndView) == 8
  doAssert offsetof(HciAclDataIndView, length) == 2
  doAssert offsetof(HciAclDataIndView, dataAddr) == 4
  doAssert sizeof(LldAclRxIndView) == 5
  doAssert offsetof(LldAclRxIndView, length) == 2
  doAssert offsetof(LldAclRxIndView, llidFlags) == 4
  doAssert sizeof(HciLeCreateConnReqView) == 25
  doAssert offsetof(HciLeCreateConnReqView, peerAddrType) == 5
  doAssert offsetof(HciLeCreateConnReqView, peerAddr) == 6
  doAssert offsetof(HciLeCreateConnReqView, ownAddrType) == 12
  doAssert offsetof(HciLeCreateConnReqView, connIntervalMin) == 13
  doAssert offsetof(HciLeCreateConnReqView, connLatency) == 17
  doAssert offsetof(HciLeCreateConnReqView, supervisionTimeout) == 19
  doAssert sizeof(HciLeConnUpdateReqView) == 14
  doAssert offsetof(HciLeConnUpdateReqView, connIntervalMin) == 2
  doAssert offsetof(HciLeConnUpdateReqView, connLatency) == 6
  doAssert offsetof(HciLeConnUpdateReqView, supervisionTimeout) == 8
  doAssert sizeof(HciLeSetPhyReqView) == 7
  doAssert offsetof(HciLeSetPhyReqView, txPhys) == 3
  doAssert offsetof(HciLeSetPhyReqView, rxPhys) == 4
  doAssert sizeof(HciLeSetDataLenReqView) == 6
  doAssert offsetof(HciLeSetDataLenReqView, txOctets) == 2
  doAssert offsetof(HciLeSetDataLenReqView, txTime) == 4
  doAssert sizeof(HciLeSuggestedDataLenReqView) == 4
  doAssert offsetof(HciLeSuggestedDataLenReqView, txTime) == 2
  doAssert sizeof(HciLeSetAdvSetRandomAddressReqView) == 7
  doAssert offsetof(HciLeSetAdvSetRandomAddressReqView, randomAddress) == 1
  doAssert sizeof(HciConnHandleReqView) == 2
  doAssert offsetof(HciConnHandleReqView, handle) == 0
  doAssert sizeof(HciDisconnectReqView) == 3
  doAssert offsetof(HciDisconnectReqView, reason) == 2
  doAssert sizeof(HciLeSetRandomAddressReqView) == 6
  doAssert sizeof(HciLeSetAdvParamsReqView) == 15
  doAssert sizeof(HciLeDataPayloadReqView) == 32
  doAssert offsetof(HciLeDataPayloadReqView, payload) == 1
  doAssert sizeof(HciLeSetAdvEnableReqView) == 1
  doAssert sizeof(HciLeSetScanParamsReqView) == 7
  doAssert offsetof(HciLeSetScanParamsReqView, interval) == 1
  doAssert offsetof(HciLeSetScanParamsReqView, ownAddrType) == 5
  doAssert sizeof(HciLeSetScanEnableReqView) == 2
  doAssert sizeof(HciWriteAuthPayloadTimeoutReqView) == 4
  doAssert offsetof(HciWriteAuthPayloadTimeoutReqView, timeout) == 2

# ---------------------------------------------------------------------------
# LLC / LLD / LLM types (opaque state structs)
# ---------------------------------------------------------------------------

type
  LlcConEnv* = object
    ## Per-connection LLC environment (opaque, ~420 bytes from disasm)
    storage*: array[420, uint8]

  LlcConnectionRuntimeView {.packed.} = object
    connectionTimingPrefix*: array[14, uint8]
    connInterval*: uint16
    connLatency*: uint16
    authPayloadPrefix*: array[40, uint8]
    authPayloadTimeout*: uint16
    authPayloadRealTimeout*: uint16
    linkStatePrefix*: array[66, uint8]
    linkFlags*: uint16
    llcpStateFlags*: uint8

  LlcChannelAssessmentView {.packed.} = object
    channelAssessmentPrefix*: array[344, uint8]
    flags*: uint16
    channelMap*: array[5, uint8]

  LlcDisconnectStateView {.packed.} = object
    disconnectStatePrefix*: array[413, uint8]
    reason*: uint8
    active*: uint8

  LldEvtEnv* = object
    ## LLD event environment
    storage*: array[256, uint8]

  LlmEnv* = object
    ## LLM environment block
    storage*: array[512, uint8]

  LlmRuntimeConfigView {.packed.} = object
    clockAccuracyMask*: uint32
    leEventMask*: array[8, uint8]
    runtimePadding12*: array[332, uint8]
    localChannelMap*: array[5, uint8]
    masterChannelMap*: array[5, uint8]
    runtimePadding354*: array[74, uint8]
    connectionAcceptTimeout*: uint16
    suggestedMaxTxOctets*: uint16
    suggestedMaxTxTime*: uint16
    runtimePadding434*: array[2, uint8]
    featureSet*: array[4, uint8]
    runtimePadding440*: array[38, uint8]
    suggestedMaxRxOctets*: uint16
    suggestedMaxRxTime*: uint16
    rxPathCompensation*: int16
    txPathCompensation*: int16
    runtimePadding486*: uint8
    advertisingInterfaceMode*: uint8

  LlmChannelMapView {.packed.} = object
    channelMapPrefix*: array[344, uint8]
    localMap*: array[5, uint8]
    masterMap*: array[5, uint8]

  LlmActivitySlotView {.packed.} = object
    advertisingParamPtr*: uint32
    schedulerPlanElement*: array[24, uint8]
    peerAddr*: BdAddr
    peerAddrType*: uint8
    activityPadding35*: array[25, uint8]
    state*: uint8
    activityTailPadding61*: array[3, uint8]

  LlmDeviceListEntryView {.packed.} = object
    deviceAddr*: BdAddr
    deviceListPadding6*: array[2, uint8]
    addrType*: uint8
    flags*: uint8

doAssert offsetof(LlcChannelAssessmentView, channelAssessmentPrefix) == 0
doAssert offsetof(LlcChannelAssessmentView, flags) == 344
doAssert offsetof(LlcChannelAssessmentView, channelMap) == 346
doAssert offsetof(LlcConnectionRuntimeView, connInterval) == 14
doAssert offsetof(LlcConnectionRuntimeView, connLatency) == 16
doAssert offsetof(LlcConnectionRuntimeView, authPayloadTimeout) == 58
doAssert offsetof(LlcConnectionRuntimeView, authPayloadRealTimeout) == 60
doAssert offsetof(LlcConnectionRuntimeView, linkFlags) == 128
doAssert offsetof(LlcConnectionRuntimeView, llcpStateFlags) == 130
doAssert offsetof(LlcDisconnectStateView, disconnectStatePrefix) == 0
doAssert offsetof(LlcDisconnectStateView, reason) == 413
doAssert offsetof(LlcDisconnectStateView, active) == 414
doAssert offsetof(LlmChannelMapView, channelMapPrefix) == 0
doAssert offsetof(LlmChannelMapView, localMap) == 344
doAssert offsetof(LlmChannelMapView, masterMap) == 349
doAssert sizeof(LlmRuntimeConfigView) == 488
doAssert offsetof(LlmRuntimeConfigView, clockAccuracyMask) == 0
doAssert offsetof(LlmRuntimeConfigView, leEventMask) == 4
doAssert offsetof(LlmRuntimeConfigView, localChannelMap) == 344
doAssert offsetof(LlmRuntimeConfigView, masterChannelMap) == 349
doAssert offsetof(LlmRuntimeConfigView, connectionAcceptTimeout) == 428
doAssert offsetof(LlmRuntimeConfigView, suggestedMaxTxOctets) == 430
doAssert offsetof(LlmRuntimeConfigView, suggestedMaxTxTime) == 432
doAssert offsetof(LlmRuntimeConfigView, featureSet) == 436
doAssert offsetof(LlmRuntimeConfigView, suggestedMaxRxOctets) == 478
doAssert offsetof(LlmRuntimeConfigView, suggestedMaxRxTime) == 480
doAssert offsetof(LlmRuntimeConfigView, rxPathCompensation) == 482
doAssert offsetof(LlmRuntimeConfigView, txPathCompensation) == 484
doAssert offsetof(LlmRuntimeConfigView, advertisingInterfaceMode) == 487
doAssert sizeof(LlmActivitySlotView) == 64
doAssert offsetof(LlmActivitySlotView, advertisingParamPtr) == 0
doAssert offsetof(LlmActivitySlotView, schedulerPlanElement) == 4
doAssert offsetof(LlmActivitySlotView, peerAddr) == 28
doAssert offsetof(LlmActivitySlotView, peerAddrType) == 34
doAssert offsetof(LlmActivitySlotView, state) == 60
doAssert sizeof(LlmDeviceListEntryView) == 10
doAssert offsetof(LlmDeviceListEntryView, deviceAddr) == 0
doAssert offsetof(LlmDeviceListEntryView, addrType) == 8
doAssert offsetof(LlmDeviceListEntryView, flags) == 9

# ---------------------------------------------------------------------------
# ECC types
# ---------------------------------------------------------------------------

type
  EccPoint256* {.packed.} = object
    x*: array[ECC_KEY_LEN, uint8]
    y*: array[ECC_KEY_LEN, uint8]

# ---------------------------------------------------------------------------
# Global state (kernel environment)
# ---------------------------------------------------------------------------

var
  # co_list patch function pointer(s)
  co_list_init_patch: proc(a0: uint32, list: ptr CoList): int32 {.cdecl.}
  co_list_push_back_patch: proc(a0: uint32, list: ptr CoList, node: ptr CoListNode): int32 {.cdecl.}
  co_list_push_front_patch: proc(a0: uint32, list: ptr CoList, node: ptr CoListNode): int32 {.cdecl.}
  co_list_pop_front_patch: proc(result_out: ptr pointer, list: ptr CoList): int32 {.cdecl.}
  co_list_extract_patch: proc(found: ptr uint8, list: ptr CoList, node: ptr CoListNode, count: uint32): int32 {.cdecl.}
  co_list_extract_after_patch: proc(a0: uint32, list: ptr CoList, prev: ptr CoListNode, node: ptr CoListNode): int32 {.cdecl.}
  co_list_find_patch: proc(result_out: ptr pointer, list: ptr CoList, node: ptr CoListNode): int32 {.cdecl.}
  co_list_merge_patch: proc(a0: uint32, dest: ptr CoList, src: ptr CoList): int32 {.cdecl.}
  co_list_insert_before_patch: proc(a0: uint32, list: ptr CoList, before_node: ptr CoListNode, node: ptr CoListNode): int32 {.cdecl.}
  co_list_insert_after_patch: proc(a0: uint32, list: ptr CoList, after_node: ptr CoListNode, node: ptr CoListNode): int32 {.cdecl.}
  co_list_size_patch: proc(result_out: ptr uint32, list: ptr CoList): int32 {.cdecl.}
  co_list_check_size_available_patch: proc(result_out: ptr uint8, list: ptr CoList, limit: uint32): int32 {.cdecl.}

  # ke_event
  kePendingEventBits*: uint32
  ke_event_slots*: array[KE_EVENT_MAX, KeEventSlot]

  ke_event_init_patch: proc(a0: uint32): int32 {.cdecl.}
  ke_event_callback_set_patch: proc(status: ptr uint8, eventId: uint8, cb: KeEventCallback): int32 {.cdecl.}
  ke_event_set_patch: proc(a0: uint32, eventId: uint8): int32 {.cdecl.}
  ke_event_clear_patch: proc(a0: uint32, eventId: uint8): int32 {.cdecl.}
  ke_event_get_all_patch: proc(result_out: ptr uint32): int32 {.cdecl.}
  ke_event_flush_patch: proc(): int32 {.cdecl.}
  ke_event_schedule_patch: proc(a0: uint32): int32 {.cdecl.}

  # ke_mem
  ke_mem_heap*: ptr uint8
  ke_mem_heap_end*: ptr uint8

  ke_mem_is_in_heap_patch: proc(result_out: ptr uint8, p: pointer): int32 {.cdecl.}
  ke_mem_init_patch: proc(a0: uint32): int32 {.cdecl.}

  # ke_malloc/free
  ke_malloc_patch: proc(result_out: ptr pointer, size: uint32, mtype: uint32): int32 {.cdecl.}
  ke_free_patch: proc(a0: uint32, p: pointer): int32 {.cdecl.}
  ke_is_free_patch: proc(result_out: ptr uint8, p: pointer): int32 {.cdecl.}

  # ke_msg
  ke_msg_alloc_patch: proc(result_out: ptr pointer, id: KeMsgId, dest: KeTaskId,
                            src: KeTaskId, plen: uint16): int32 {.cdecl.}
  ke_msg_send_patch: proc(a0: uint32, param: pointer): int32 {.cdecl.}
  ke_msg_get_sent_num_patch: proc(result_out: ptr uint32, id: KeMsgId): int32 {.cdecl.}
  ke_msg_send_basic_patch: proc(a0: uint32, id: KeMsgId, dest: KeTaskId, src: KeTaskId): int32 {.cdecl.}
  ke_msg_free_patch: proc(a0: uint32, msg: ptr KeMsgHeader): int32 {.cdecl.}

  # ke_queue
  ke_queue_extract_patch: proc(a0: uint32, queue: ptr CoList, cmp: pointer, arg: pointer): int32 {.cdecl.}
  ke_queue_insert_patch: proc(a0: uint32, queue: ptr CoList, node: ptr CoListNode, cmp: pointer): int32 {.cdecl.}

  # ke_task
  ke_task_desc*: array[KE_TASK_MAX, KeTaskDesc]
  ke_task_saved*: array[KE_TASK_MAX, ptr KeStateHandler]

  ke_task_saved_update_patch: proc(a0: uint32, task_type: uint16): int32 {.cdecl.}
  ke_handler_search_patch: proc(result_out: ptr pointer, msg_id: KeMsgId, task_desc: ptr KeTaskDesc): int32 {.cdecl.}
  ke_task_handler_get_patch: proc(result_out: ptr pointer, msg_id: KeMsgId, task_id: KeTaskId): int32 {.cdecl.}
  ke_task_schedule_patch: proc(a0: uint32): int32 {.cdecl.}
  ke_task_init_patch: proc(a0: uint32): int32 {.cdecl.}
  ke_task_create_patch: proc(a0: uint32, task_type: uint8, desc: ptr KeTaskDesc): int32 {.cdecl.}
  ke_state_set_patch: proc(a0: uint32, task_id: KeTaskId, state: uint8): int32 {.cdecl.}
  ke_state_get_patch: proc(result_out: ptr uint8, task_id: KeTaskId): int32 {.cdecl.}

  # ke_time / ke_timer
  ke_time_patch: proc(result_out: ptr uint32): int32 {.cdecl.}
  ke_time_cmp_patch: proc(result_out: ptr uint8, t1: uint32, t2: uint32): int32 {.cdecl.}
  ke_time_past_patch: proc(result_out: ptr uint8, t: uint32): int32 {.cdecl.}
  ke_timer_hw_set_patch: proc(a0: uint32, timer: ptr KeTimer): int32 {.cdecl.}
  ke_timer_schedule_patch: proc(a0: uint32): int32 {.cdecl.}
  ke_timer_init_patch: proc(a0: uint32): int32 {.cdecl.}
  ke_timer_set_patch: proc(a0: uint32, id: uint16, task: uint16, delay: uint32): int32 {.cdecl.}
  ke_timer_clear_patch: proc(a0: uint32, id: uint16, task: uint16): int32 {.cdecl.}
  ke_timer_active_patch: proc(result_out: ptr uint8, id: uint16, task: uint16): int32 {.cdecl.}
  ke_timer_target_get_patch: proc(result_out: ptr uint32): int32 {.cdecl.}

  # ke_init / flush / sleep
  ke_init_patch: proc(a0: uint32): int32 {.cdecl.}
  ke_flush_patch: proc(a0: uint32): int32 {.cdecl.}
  ke_sleep_check_patch: proc(result_out: ptr uint8): int32 {.cdecl.}

  # ke misc compare patches
  cmp_abs_time_patch: proc(a0: uint32, t1: pointer, t2: pointer): int32 {.cdecl.}
  cmp_timer_id_patch: proc(a0: uint32, t1: pointer, t2: pointer): int32 {.cdecl.}
  cmp_dest_id_patch: proc(a0: uint32, a1: pointer, a2: pointer): int32 {.cdecl.}

  # Kernel message queue
  ke_msg_queue*: CoList
  ke_timer_list*: CoList

  # Debug level
  ble_debug_level*: uint32

  # TX power
  ble_tx_pwr*: int8

  # Scan channel / filter
  ble_scan_chan_fixed*: uint8
  ble_scan_filter_table_size*: uint16

  # ADV rand(om) delay disable flag
  ble_adv_random_delay_disabled*: bool

  # Ongoing programming flag
  ble_programming_ongoing*: ptr uint32

  # ADV discarded notification callback
  ble_adv_discarded_callback*: proc(count: uint32) {.cdecl.}

  # Sleep prevention bitmask
  bflbip_prevent_sleep_mask*: uint32

  # Sleep enable flag
  bflbip_sleep_enabled*: bool

  # External wakeup enable
  bflbip_ext_wakeup*: bool

  # Sleep duration / stat counters
  bflbip_sw_wakeup_cnt*: uint32
  bflbip_sleep_dur_cnt*: uint32
  bflbip_sleep_stat_cnt*: uint32

  nim_btble_sw_pending: bool

  # Deep sleep stat
  ble_deep_sleep_stat*: uint32

  # Wakeup delay
  bflbip_wakeup_delay*: uint32

  # Wlcoex configuration
  bflbip_wlcoex_cfg*: uint32

  # Controller lib version string
  ble_controller_lib_ver: cstring = "bl808-blecontroller-nim-1.0"

  # RTOS task handle
  ble_controller_task_handle*: pointer

  # Main task queue handle
  bflb_main_queue_handle*: pointer

  # Main task function pointer
  bflb_main_task_func*: pointer

  # Trace malloc info
  trace_malloc_info*: array[16, uint32]
  trace_malloc_idx*: uint32

  # EM buf global state
  em_buf_env*: array[512, uint8]  ## large enough for the em_buf environment

  # EA global state
  ea_env_list*: CoList
  ea_env_interval_list*: CoList
  ea_env_target*: uint32
  ea_env_finetarget*: uint32

  # HCI global state
  hci_env*: array[256, uint8]
  hci_evt_mask*: array[8, uint8]
  hci_le_evt_mask*: array[8, uint8]
  hci_fc_env*: HciFlowControl

  # LLC global
  llc_env*: array[LLC_CON_MAX, ptr LlcConEnv]
  llc_env_storage*: array[LLC_CON_MAX, LlcConEnv]

  # LLD global
  lld_evt_env_storage*: array[512, uint8]

  # LLM global
  llm_env_storage*: LlmEnv
  llm_wl*: array[LLM_WL_MAX, BdAddr]
  llm_wl_type*: array[LLM_WL_MAX, uint8]

  # ECC state
  ecc_env*: array[512, uint8]
  ecc_ongoing*: bool
  ecc_private_key*: array[ECC_KEY_LEN, uint8]

  # RF state
  rf_pwr_offset*: int8
  rf_pwr_offset_table*: ptr int8
  rf_pwr_max*: int8

  # PKA state
  pka_result*: array[ECC_KEY_LEN * 2, uint8]

  # On-chip HCI
  onchiphci_env*: array[64, uint8]
  onchiphci_recv_cb*: OnChipHciRecvCb
  onchiphci_cb_payload*: array[260, uint8]
  nim_adv_params* {.exportc.}: array[15, uint8]
  nim_adv_event_props*: uint16
  nim_scan_params*: array[7, uint8]
  nim_adv_data* {.exportc.}: array[31, uint8]
  nim_scan_rsp_data* {.exportc.}: array[31, uint8]
  nim_local_addr*: array[6, uint8]
  nim_local_addr_valid*: bool
  nim_public_addr*: array[6, uint8]
  nim_public_addr_valid*: bool
  nim_adv_data_len* {.exportc.}: uint8
  nim_scan_rsp_data_len* {.exportc.}: uint8
  nim_adv_enabled* {.exportc.}: bool
  nim_scan_enabled*: bool
  nim_conn_active*: bool
  nim_conn_handle*: uint16
  nim_auth_payload_timeout*: uint16
  nim_suggested_tx_octets*: uint16 = NimBleLeMaxDataOctets
  nim_suggested_tx_time*: uint16 = NimBleLeMaxDataTime
  nim_ble_core_ready*: bool
  nim_adv_schedule_slot: uint8
  nim_adv_target_half_us: uint32
  nim_ble_dbg_isr_count* {.exportc.}: uint32
  nim_ble_dbg_isr_stat_or* {.exportc.}: uint32
  nim_ble_dbg_stat20_count* {.exportc.}: uint32
  nim_ble_dbg_stat8000_count* {.exportc.}: uint32
  nim_ble_dbg_push_count* {.exportc.}: uint32
  nim_ble_dbg_rx_ready_count* {.exportc.}: uint32
  nim_ble_dbg_rx_scan_req_count* {.exportc.}: uint32
  nim_ble_dbg_rx_scan_req_match_count* {.exportc.}: uint32
  nim_ble_dbg_rx_scan_req_last_scana0* {.exportc.}: uint32
  nim_ble_dbg_rx_scan_req_last_scana1* {.exportc.}: uint32
  nim_ble_dbg_rx_scan_req_last_adva0* {.exportc.}: uint32
  nim_ble_dbg_rx_scan_req_last_adva1* {.exportc.}: uint32
  nim_ble_dbg_rx_connect_ind_count* {.exportc.}: uint32
  nim_ble_dbg_rx_last_header* {.exportc.}: uint32
  nim_ble_dbg_rx_last_status* {.exportc.}: uint32
  nim_ble_dbg_rx_last_desc* {.exportc.}: uint32
  nim_ble_dbg_rx_last_buf* {.exportc.}: uint32
  nim_hci_debug_stage* {.exportc.}: uint32
  nim_hci_debug_opcode* {.exportc.}: uint32
  nim_hci_debug_status* {.exportc.}: uint32
  nim_hci_debug_len* {.exportc.}: uint32
  nim_hci_debug_cb* {.exportc.}: uint32
  nim_adv_debug_stage* {.exportc.}: uint32
  nim_adv_debug_detail* {.exportc.}: uint32

  # Coex stats
  coex_ble_dump_buf*: array[32, uint8]

  one_bits* {.exportc.}: array[16, uint8] =
    [0'u8, 1, 1, 2, 1, 2, 2, 3, 1, 2, 2, 3, 2, 3, 3, 4]

proc rwip_prevent_sleep_set*(mask: uint16) {.exportc, cdecl.}
proc rwip_prevent_sleep_clear*(mask: uint16) {.exportc, cdecl.}
proc lld_aa_gen*(outAddr: ptr uint8, seed: uint8) {.exportc, cdecl.}
proc lld_ch_map_set*(chMap: ptr uint8) {.exportc, cdecl.}

when defined(bl808m0) and bl808BleNimPureCentral:
  const NimScanPeerHintSlots = 8
  var nim_scan_program_count* {.exportc.}: uint32
  var nim_scan_event_count* {.exportc.}: uint32
  var nim_scan_last_event* {.exportc.}: uint32
  var nim_scan_last_status* {.exportc.}: uint32
  var nim_scan_next_program_at* {.exportc.}: uint32
  var nim_scan_channel_cursor* {.exportc.}: uint8
  var nim_scan_last_channel_index* {.exportc.}: uint32
  var nim_scan_last_adv_channel* {.exportc.}: uint32
  var nim_scan_req_peer_addr_type* {.exportc.}: uint32
  var nim_scan_peer_hint_write_index* {.exportc.}: uint32
  var nim_scan_peer_hint_addr0* {.exportc.}: array[NimScanPeerHintSlots, uint32]
  var nim_scan_peer_hint_addr1* {.exportc.}: array[NimScanPeerHintSlots, uint32]
  var nim_scan_peer_hint_type* {.exportc.}: array[NimScanPeerHintSlots, uint32]
  var nim_scan_peer_hint_channel_index* {.exportc.}: array[NimScanPeerHintSlots, uint32]
  var nim_scan_peer_hint_adv_channel* {.exportc.}: array[NimScanPeerHintSlots, uint32]
  var nim_init_active* {.exportc.}: uint32
  var nim_init_program_count* {.exportc.}: uint32
  var nim_init_event_count* {.exportc.}: uint32
  var nim_init_match_count* {.exportc.}: uint32
  var nim_init_start_count* {.exportc.}: uint32
  var nim_init_complete_count* {.exportc.}: uint32
  var nim_init_hci_complete_count* {.exportc.}: uint32
  var nim_init_cancel_count* {.exportc.}: uint32
  var nim_init_tx_event_count* {.exportc.}: uint32
  var nim_init_last_status* {.exportc.}: uint32
  var nim_init_last_event* {.exportc.}: uint32
  var nim_init_last_rx_clock* {.exportc.}: uint32
  var nim_init_last_rx_fine* {.exportc.}: uint32
  var nim_init_last_anchor* {.exportc.}: uint32
  var nim_init_last_access_addr* {.exportc.}: uint32
  var nim_init_rx_count* {.exportc.}: uint32
  var nim_init_rx_match_reason* {.exportc.}: uint32
  var nim_init_rx_last_header* {.exportc.}: uint32
  var nim_init_rx_last_status* {.exportc.}: uint32
  var nim_init_rx_last_buf* {.exportc.}: uint32
  var nim_init_rx_last_peer0* {.exportc.}: uint32
  var nim_init_rx_last_peer1* {.exportc.}: uint32
  var nim_init_rx_pdu_mismatch_count* {.exportc.}: uint32
  var nim_init_rx_short_count* {.exportc.}: uint32
  var nim_init_rx_addr_mismatch_count* {.exportc.}: uint32
  var nim_init_rx_addr_match_count* {.exportc.}: uint32
  var nim_init_rx_type_mismatch_count* {.exportc.}: uint32
  var nim_init_total_rx_count* {.exportc.}: uint32
  var nim_init_total_match_count* {.exportc.}: uint32
  var nim_init_total_pdu_mismatch_count* {.exportc.}: uint32
  var nim_init_total_short_count* {.exportc.}: uint32
  var nim_init_total_addr_mismatch_count* {.exportc.}: uint32
  var nim_init_total_addr_match_count* {.exportc.}: uint32
  var nim_init_total_type_mismatch_count* {.exportc.}: uint32
  var nim_init_total_handoff_start_count* {.exportc.}: uint32
  var nim_init_total_handoff_timeout_count* {.exportc.}: uint32
  var nim_init_total_start_count* {.exportc.}: uint32
  var nim_init_total_tx_event_count* {.exportc.}: uint32
  var nim_init_total_hci_complete_count* {.exportc.}: uint32
  var nim_init_connect_ind_header_flags* {.exportc.}: uint32
  var nim_init_rx_log_index* {.exportc.}: uint32
  var nim_init_rx_header_log* {.exportc.}: array[8, uint32]
  var nim_init_rx_status_log* {.exportc.}: array[8, uint32]
  var nim_init_rx_peer0_log* {.exportc.}: array[8, uint32]
  var nim_init_rx_peer1_log* {.exportc.}: array[8, uint32]
  var nim_init_rx_reason_log* {.exportc.}: array[8, uint32]
  var nim_init_next_program_at* {.exportc.}: uint32
  var nim_init_event_target_clock* {.exportc.}: uint32
  var nim_init_rx_event_clock* {.exportc.}: uint32
  var nim_init_last_rx_now* {.exportc.}: uint32
  var nim_init_last_rx_event_clock* {.exportc.}: uint32
  var nim_init_last_rx_clock_source* {.exportc.}: uint32
  var nim_init_rx_service_pending* {.exportc.}: uint32
  var nim_init_rx_service_program_count* {.exportc.}: uint32
  var nim_init_rx_service_deadline* {.exportc.}: uint32
  var nim_init_event_done_program_count* {.exportc.}: uint32
  var nim_init_handoff_pending* {.exportc.}: uint32
  var nim_init_handoff_program_count* {.exportc.}: uint32
  var nim_init_handoff_tx_event_count* {.exportc.}: uint32
  var nim_init_handoff_ready_clock* {.exportc.}: uint32
  var nim_init_handoff_deadline* {.exportc.}: uint32
  var nim_init_handoff_start_count* {.exportc.}: uint32
  var nim_init_handoff_timeout_count* {.exportc.}: uint32
  var nim_init_pending_header* {.exportc.}: uint32
  var nim_init_pending_rx_clock* {.exportc.}: uint32
  var nim_init_pending_rx_fine* {.exportc.}: uint32
  var nim_init_pending_desc* {.exportc.}: uint32
  var nim_init_pending_desc_status* {.exportc.}: uint32
  var nim_init_pending_desc_idx* {.exportc.}: uint32
  var nim_init_channel_cursor* {.exportc.}: uint8
  var nim_init_channel_seed* {.exportc.}: uint32
  var nim_init_channel_window_valid* {.exportc.}: uint32
  var nim_init_channel_window_deadline* {.exportc.}: uint32
  var nim_init_last_channel_index* {.exportc.}: uint32
  var nim_init_last_adv_channel* {.exportc.}: uint32
  var nim_init_channel_hint_hit_count* {.exportc.}: uint32
  var nim_init_channel_hint_miss_count* {.exportc.}: uint32
  var nim_init_channel_hint_index* {.exportc.}: uint32
  var nim_init_channel_hint_adv_channel* {.exportc.}: uint32
  var nim_init_complete_pending* {.exportc.}: uint32
  var nim_init_hci_params* {.exportc.}: array[25, uint8]
  var nim_init_ll_data* {.exportc.}: array[22, uint8]
  when defined(BleDebugCounters):
    var nim_init_program_snapshot_count* {.exportc.}: uint32
    var nim_init_program_snapshot_channel* {.exportc.}: uint32
    var nim_init_program_snapshot_timing* {.exportc.}: array[8, uint32]
    var nim_init_program_snapshot_em* {.exportc.}: array[18, uint32]
    var nim_init_program_snapshot_tx_desc* {.exportc.}: array[4, uint32]
    var nim_init_program_snapshot_sched* {.exportc.}: array[8, uint32]
    var nim_init_sch_event_log_index* {.exportc.}: uint32
    var nim_init_sch_event_code_log* {.exportc.}: array[16, uint32]
    var nim_init_sch_event_time_log* {.exportc.}: array[16, uint32]
    var nim_init_sch_event_now_log* {.exportc.}: array[16, uint32]
    var nim_init_sch_event_state_log* {.exportc.}: array[16, uint32]
    var nim_init_sch_event_counts_log* {.exportc.}: array[16, uint32]
    var nim_init_sch_event_done_log* {.exportc.}: array[16, uint32]
    var nim_init_sch_event_int_log* {.exportc.}: array[16, uint32]
    var nim_init_handoff_snapshot_count* {.exportc.}: uint32
    var nim_init_handoff_snapshot_reason* {.exportc.}: uint32
    var nim_init_handoff_snapshot_timing* {.exportc.}: array[16, uint32]
    var nim_init_handoff_snapshot_em* {.exportc.}: array[64, uint32]
    var nim_init_handoff_snapshot_desc* {.exportc.}: array[32, uint32]
    var nim_init_handoff_snapshot_data* {.exportc.}: array[32, uint32]
  var nim_scan_debug_stage* {.exportc.}: uint32
  var nim_scan_debug_now* {.exportc.}: uint32
  var nim_scan_debug_target* {.exportc.}: uint32
  var nim_scan_debug_lead* {.exportc.}: uint32

var sch_slice_params* {.exportc.}: array[8, uint16]

when defined(bl808m0) and
    bl808BleNimSchProgEnabled:
  var nim_sch_prog: array[36, uint8]
  var nim_adv_sch_program_count* {.exportc.}: uint32
  var nim_adv_sch_event_count* {.exportc.}: uint32
  var nim_adv_sch_end_count* {.exportc.}: uint32
  var nim_adv_sch_last_event* {.exportc.}: uint32
  var nim_adv_sch_event_active* {.exportc.}: uint32

  proc nimSchProgCb(arg0: uint32, ctx: pointer,
                          event: uint8) {.exportc, cdecl.} =
    discard arg0
    discard ctx
    nim_adv_sch_last_event = event.uint32
    inc nim_adv_sch_event_count
    case event
    of 0'u8, 1'u8, 4'u8, 7'u8, 0xFF'u8:
      nim_adv_sch_event_active = 0
      inc nim_adv_sch_end_count
    else:
      discard

when defined(bl808m0):
  var nim_lld_adv_params: array[40, uint8]

  when not bl808BleNimConnectionEnabled:
    var nim_lld_adv_rand_state: uint32 = 0x12345678'u32

    proc rand*(): cint {.exportc, cdecl.} =
      nim_lld_adv_rand_state =
        nim_lld_adv_rand_state * 1103515245'u32 + 12345'u32
      cint((nim_lld_adv_rand_state shr 16) and 0x7FFF'u32)

template llcChannelAssessment(env: ptr LlcConEnv): ptr LlcChannelAssessmentView =
  cast[ptr LlcChannelAssessmentView](env)

template llcConnectionRuntime(env: ptr LlcConEnv): ptr LlcConnectionRuntimeView =
  cast[ptr LlcConnectionRuntimeView](env)

template llcDisconnectState(env: ptr LlcConEnv): ptr LlcDisconnectStateView =
  cast[ptr LlcDisconnectStateView](env)

template llmChannelMaps(): ptr LlmChannelMapView =
  cast[ptr LlmChannelMapView](addr llm_env_storage)

template llmRuntimeConfig(): ptr LlmRuntimeConfigView =
  cast[ptr LlmRuntimeConfigView](addr llm_env_storage)

template llmActivitySlot(activityIndex: int): ptr LlmActivitySlotView =
  addr cast[ptr UncheckedArray[LlmActivitySlotView]](
    addr llm_env_storage.storage[12])[activityIndex]

template llmDeviceListEntry(deviceListIndex: int): ptr LlmDeviceListEntryView =
  addr cast[ptr UncheckedArray[LlmDeviceListEntryView]](
    addr llm_env_storage.storage[356])[deviceListIndex]

template llmAdvertiserConn(): ptr LlmAdvertiserConnView =
  cast[ptr LlmAdvertiserConnView](addr llm_env_storage)

proc bleCentralTraceReadSp(): uint32 {.inline.} =
  var stackPointer: uint32
  {.emit: ["asm volatile(\"mv %0, sp\" : \"=r\"(", stackPointer, "));"].}
  stackPointer

proc bleCentralDebugMark*(stage, detail: uint32) {.exportc, cdecl.} =
  discard stage
  discard detail

proc bleCentralTraceStoreWord(offset: uint, value: uint32) {.inline.} =
  discard offset
  discard value

proc bleCentralTraceStoreRawRa(offset: uint) {.inline.} =
  discard offset

proc bleCentralTraceCheckRawRa(stage: uint32) {.inline.} =
  discard stage
