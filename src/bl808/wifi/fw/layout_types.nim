# =============================================================================
# Internal data structure offsets
# =============================================================================
const
  # sta_info_tag field offsets (byte offsets from sta entry base pointer)
  STA_INFO_IDX_OFF       = 40    # u8: info_idx / rate group index
  STA_RATE_INFO_FLAGS_OFF = 308  # u32: rate info flags (bit 1 = HT capable)
  STA_RC_STATS_PTR_OFF   = 324   # ptr: rc_sta_stats pointer (0x144)
  STA_TX_POLICY_PTR_OFF  = 320   # ptr: tx policy descriptor pointer (0x140)
  STA_HT_CAP_INFO_OFF    = 264   # u16: HT capability info (0x108)
  STA_HT_MCS_SET_OFF     = 267   # u8[]: HT MCS bitmask start (0x10B)
  STA_NSS_BW_MAX_OFF     = 313   # u8: NSS / BW max config (0x139)
  STA_SUPP_RATES_OFF     = 332   # u16: supported rates bitmap (0x14C)
  STA_RC_FLAGS_OFF       = 334   # u8: RC flags byte (0x14E)
  STA_VIF_PTR_OFF        = 28    # ptr: VIF pointer (0x1C)

  # rc_sta_stats offsets (byte offsets from rc_sta_stats base)
  # Rate table: entries 0..N at (base + i*12), 12 bytes each:
  #   +0:  attempts (u16)
  #   +2:  successes (u16)
  #   +4:  prob_ewma (u16)
  #   +6:  old_prob (u16)
  #   +8:  sample_skipped (u8) + initialized (u8)
  #   +10: rate_config (u16)
  RCS_TP_CUR         = 124   # u32: current best throughput (0x7C)
  RCS_MAX_TP_IDX     = 128   # u16: best throughput rate index (0x80)
  RCS_TP_SECOND      = 132   # u32: second best throughput (0x84)
  RCS_MAX_TP2_IDX    = 136   # u16: second best index (0x88)
  RCS_TP_THIRD       = 140   # u32: third best throughput (0x8C)
  RCS_MAX_PROB_IDX   = 144   # u16: highest probability rate index (0x90)
  RCS_RETRY_TIMER    = 148   # u32: retry chain timer (0x94)
  RCS_RESERVED_U16   = 152   # u16: reserved (0x98)
  RCS_PREV_TP        = 156   # u32: previous throughput (0x9C)
  RCS_SAMPLE_CAND    = 160   # u16: sample candidate rate (0xA0)
  RCS_TOTAL_ATTEMPTS = 164   # u16: total attempt count (0xA4)
  RCS_TOTAL_SUCCESS  = 166   # u16: total success count (0xA6)
  RCS_PROB_AVG       = 168   # u32: average probability EWMA (0xA8)
  RCS_AVG_AMPDU_LEN  = 170   # u16: average AMPDU length (0xAA)
  RCS_RETRY_LIMIT    = 172   # u8: retry limit (0xAC)
  RCS_SLOW_RATE_CNT  = 173   # u8: slow rate counter (0xAD)
  RCS_UPDATE_STAGE   = 174   # u8: update stage flag (0xAE)
  RCS_FLAGS          = 175   # u8: bit1=fixed,bit2=retry,bit6=skip (0xAF)
  RCS_ANOTHER_FLAG   = 176   # u8: secondary flag (0xB0)
  RCS_FORMAT_MOD     = 177   # u8: 0=legacy,2=HT,4=VHT (0xB1)
  RCS_RATE_BITMAP    = 178   # u8[4]: MCS bitmaps per NSS group (0xB2)
  RCS_RATE_MAP       = 182   # u16: supported rate bitmap (0xB6)
  RCS_MAX_NSS_MCS    = 184   # u8: max MCS per NSS, 0xFF=legacy (0xB8)
  RCS_LOWEST_IDX     = 185   # u8: lowest rate index (0xB9)
  RCS_HIGHEST_IDX    = 186   # u8: highest rate index (0xBA)
  RCS_NO_SS          = 187   # u8: number of spatial streams (0xBB)
  RCS_GROUP_CNT      = 188   # u8: max NSS group index (0xBC)
  RCS_SHORT_GI       = 189   # u8: short GI support (0xBD)
  RCS_BW_MAX         = 190   # u8: max bandwidth index (0xBE)
  RCS_N_RATES        = 192   # u16: total supported rate count (0xC0)
  RCS_RATE_MAP_L     = 194   # u16: legacy rate map (0xC2)
  RCS_SAMPLE_IDX     = 198   # u16: sample index, 0xFFFF=none (0xC6)

# Linked list node
type
  BlOpsFuncs {.importc: "bl_ops_funcs_t", header: "bl_os_adapter.h".} = object

  BlOpsDataView {.packed.} = object
    callbacks*: array[4, pointer]
    macWord0*: uint32
    macWord1*: uint32
    beaconTimeoutConfig*: array[4, uint8]
    adapterTimingConfig28*: uint32
    beaconProbeCountdown*: uint32
    adapterTimingConfig36*: uint32
    adapterTimingConfig40*: uint32
    adapterTimingConfig44*: uint32

  CoListHdr* = object
    next*: ptr CoListHdr

  CoList* = object
    first*: ptr CoListHdr
    last*: ptr CoListHdr

  NotifierNodeView {.packed.} = object
    callback*: pointer
    next*: pointer
    priority*: int32

  ElementNotifyContextView {.packed.} = object
    reserved00*: array[8, uint8]
    state*: pointer

  KeEnvPsFlagsView {.packed.} = object
    flags*: uint8
    apPending*: uint8
    reserved30*: uint8
    otherPending*: uint8
    staPending*: uint8

  TxControlAcView {.packed.} = object
    current*: pointer
    pending*: CoList
    packetCount*: uint16
    reserved14*: uint16

  TxControlEnvView {.packed.} = object
    ac*: array[5, TxControlAcView]
    packetCounter*: uint32
    seqCounter*: uint16
    reserved86*: array[2, uint8]
    resetInProgress*: uint8
    reserved89*: array[3, uint8]

  TxCfmEnvView {.packed.} = object
    lists*: array[5, CoList]

  MachwTxQueueRegsView {.packed.} = object
    reserved000*: array[0x78, uint8]
    txStatus*: uint32
    readyAck*: uint32
    genMasked*: uint32
    genRaw*: uint32
    txAggSet*: uint32
    txAggActive*: uint32
    reserved090*: array[0xF0, uint8]
    txTrigger*: uint32
    reserved184*: uint32
    dmaStatus*: uint32
    reserved18c*: array[12, uint8]
    beaconHead*: uint32
    ac0Head*: uint32
    ac1Head*: uint32
    ac2Head*: uint32
    ac3Head*: uint32

  MachwRxDmaRegsView {.packed.} = object
    reserved000*: array[0x180, uint8]
    trigger*: uint32
    reserved184*: array[0x34, uint8]
    hdSubmittedHead*: uint32
    pdSubmittedHead*: uint32
    reserved1c0*: array[0x388, uint8]
    hdHwHead*: uint32
    pdHwHead*: uint32

  MachwSecurityRegsView {.packed.} = object
    reserved000*: array[0xAC, uint8]
    keyMaterial*: array[4, uint32]
    dataLow*: uint32
    dataHigh*: uint32
    control*: uint32
    reserved0c8*: array[0x10, uint8]
    keyCount*: uint32

  WlanCoexRegsView {.packed.} = object
    control*: uint32
    pti*: uint32
    status*: uint32

  PtaCoexRegsView {.packed.} = object
    reserved000*: array[4, uint8]
    control*: uint32
    reserved008*: array[0x20, uint8]
    control2*: uint32
    reserved02c*: array[0x3D8, uint8]
    mirror*: uint32
    reserved408*: array[0x20, uint8]
    clear*: uint32

  RcRateEntryView {.packed.} = object
    reserved00*: array[4, uint8]
    attempts*: uint16
    failures*: uint16
    probEwma*: uint16
    rateConfig*: uint16

  RcRateResetFieldsView {.packed.} = object
    attempts0*: uint16
    reserved02*: array[3, uint8]
    oldProb*: uint8
    sampleSkipped*: uint8
    initialized*: uint8

  RcRetrySlotView {.packed.} = object
    rateIdx*: uint16
    reserved02*: array[6, uint8]

  RcStatsCounterView {.packed.} = object
    reserved00*: array[128, uint8]
    retrySlots*: array[4, RcRetrySlotView]
    sampleCandidate*: uint16
    reserved162*: uint16
    totalAttempts*: uint16
    totalSuccess*: uint16
    reserved168*: array[2, uint8]
    avgAmpduLen*: uint16
    retryLimit*: uint8
    slowRateCount*: uint8
    updateStage*: uint8
    flags*: uint8
    reserved176*: array[11, uint8]
    nssMax*: uint8
    bwMax*: uint8
    reserved189*: array[5, uint8]
    legacyRateMap*: uint16
    reserved196*: array[2, uint8]
    fixedRate*: uint16

  TxFrameEnvView {.packed.} = object
    freeList*: CoList
    usedList*: CoList
    postponedCount*: uint32

  MeEnvView {.packed.} = object
    activeMask*: uint32
    psDisableMask*: uint32
    htCaps*: array[32, uint8]
    chanConfig*: array[86, uint8]
    psMode*: uint8
    reserved127*: uint8
    defKey*: uint16
    htSupp*: uint8
    nss*: uint8
    htCapByte*: uint8
    psOn*: uint8
    reserved134*: array[2, uint8]

  MeChannelConfigEntry {.packed.} = object
    freq*: uint16
    data*: array[4, uint8]

  MeChannelConfigView {.packed.} = object
    entries*: array[14, MeChannelConfigEntry]
    count*: uint8
    reserved85*: uint8

  MeBeaconSequenceOverlay {.packed.} = object
    reserved00*: array[84, uint8]
    seqCounter*: uint16

  MmEnvView {.packed.} = object
    rxFilterBase*: uint32
    rxFilterExtra*: uint32
    edcaBkDur*: uint16
    edcaBeDur*: uint16
    edcaViDur*: uint16
    edcaVoDur*: uint16
    edcaBcnDur*: uint16
    previousState*: uint8
    hardwareMode*: uint8
    reserved20*: array[4, uint8]
    listenWindow*: uint16
    idleFlag*: uint8
    flagsHigh*: uint8
    keepAliveInterval*: uint32
    keepAliveLimit*: uint32
    keepAliveCounter*: uint32
    keepAliveTimestamp*: uint32
    rxPromiscUploadFlag*: uint32
    apPromiscUploadFlag*: uint32
    maxAmpduDuration*: uint32
    reserved56*: array[12, uint8]

  MmWmmParameterSourceView {.packed.} = object
    reserved00*: array[8, uint8]
    acBk*: uint32
    acBe*: uint32
    acVi*: uint32
    acVo*: uint32
    idlePeriod*: uint16
    idleOptions*: uint8

  MmBcnEnvView {.packed.} = object
    templatePtr*: pointer
    pendingCount*: uint32
    transmitRequested*: uint8
    active*: uint8
    deferredChange*: uint8
    reserved11*: uint8
    timQueue*: CoList

  BeaconChangeReqView {.packed.} = object
    reserved00*: array[4, uint8]
    frameLen*: uint16
    headerLen*: uint16
    flagByte*: uint8
    vifIdx*: uint8
    reserved10*: array[2, uint8]
    frameData*: UncheckedArray[uint8]

  BeaconEndDescView {.packed.} = object
    word0*: uint32
    word4*: uint32
    payloadStart*: uint32
    payloadEnd*: uint32
    status*: uint32

  TimDescView {.packed.} = object
    magic*: uint32
    next*: pointer
    payloadStart*: pointer
    payloadEnd*: pointer
    status*: uint32
    bitmapMagic*: uint32
    bitmapNext*: pointer
    bitmapStart*: pointer
    bitmapEnd*: pointer

  VifMgmtEnvView {.packed.} = object
    freeList*: CoList
    activeList*: CoList
    staCount*: uint8
    apCount*: uint8
    primaryApIdx*: uint8
    reserved19*: uint8

  VifMgmtHostapdOpsEnvView {.packed.} = object
    reserved00*: array[12, uint8]
    hostapdOps*: pointer

  VifHostapdPrivView {.packed.} = object
    reserved00*: array[364, uint8]
    hostapdPriv*: pointer

  VifApProbeSsidOverlay {.packed.} = object
    reserved00*: array[385, uint8]
    hiddenSsidMode*: uint8
    ssidLen*: uint8
    ssidData*: UncheckedArray[uint8]

  HostapdOpsView {.packed.} = object
    reserved00*: array[44, uint8]
    eapolRx*: pointer

  PsEnvView {.packed.} = object
    enabled*: uint8
    mode*: uint8
    reserved02*: array[2, uint8]
    statusFlags*: uint32
    pendingCount*: uint8
    reserved09*: array[3, uint8]
    nullRetryLimit*: uint32
    uapsdTimerCallback*: pointer
    reserved20*: array[8, uint8]
    uapsdTimerActive*: uint8
    psActive*: uint8
    reserved30*: array[2, uint8]
    uapsdPeriod*: uint32
    txNullTimerWord*: uint32
    txNullTimerCallback*: pointer
    currentVif*: pointer
    uapsdTimerState*: uint8
    reserved49*: array[3, uint8]
    flags*: uint8
    deferredMode*: uint8
    reserved54*: array[2, uint8]

  PsDozeEnvView {.packed.} = object
    base*: PsEnvView
    dozeInProgress*: uint32
    preState*: uint8
    reserved61*: array[3, uint8]

  SmEnvView {.packed.} = object
    connectInfo*: pointer
    connectIndMsg*: pointer
    pendingBssParams*: CoList
    joinBssFlag*: uint8
    deauthPending*: uint8
    cancelRequested*: uint8
    connectFlags*: uint8
    connectModeFlags*: uint8
    reserved21*: array[3, uint8]
    authRetryLimit*: uint32
    scanResultIndex*: uint32
    primaryFreq*: uint16
    centerFreq*: uint16
    saQueryActive*: uint8
    saQueryRetryCount*: uint8
    saQueryVifIdx*: uint8
    saQueryField39*: uint8
    saQueryTransId*: uint16
    saQueryReason*: uint16
    state*: uint8
    reserved45*: array[3, uint8]
    vendorIePtr*: pointer
    vendorIeLen*: uint16
    reserved54*: array[2, uint8]

  ApmEnvView {.packed.} = object
    connectInfo*: pointer
    pendingBssParams*: CoList
    reserved12*: array[4, uint8]
    pendingBeaconBuffer*: pointer
    securityIe*: array[64, uint8]
    cryptoType*: uint8
    beaconIntervalIndex*: uint8
    flags*: uint8
    staCount*: uint8
    maxSta*: uint8
    vifIdx*: uint8
    selfStaIdx*: uint8
    slotArea*: array[81, uint8]
    hostapdCtx*: pointer

  ApmStaSlotOverlay {.packed.} = object
    reserved00*: array[12, uint8]
    macAddr*: array[6, uint8]
    reserved18*: array[2, uint8]
    staHandle*: pointer
    active*: uint8
    staIdx*: uint8

  ConnectInfoView {.packed.} = object
    ssidLen*: uint8
    ssid*: array[33, uint8]
    bssid*: array[6, uint8]
    channelHint*: array[8, uint8]
    channelDuration*: uint32
    ctrlPortEthertype*: uint16
    listenInterval*: uint16
    psOptions*: uint8
    authType*: uint8
    qosInfo*: uint8
    vifIdx*: uint8
    authRetry*: uint8
    authRetryGate*: uint8

  ConnectInfoCredentialOverlay {.packed.} = object
    base*: ConnectInfoView
    keyString*: array[64, uint8]
    altSsid*: array[64, uint8]

  ConnectInfoChannelContextOverlay {.packed.} = object
    base*: ConnectInfoCredentialOverlay
    reserved190*: array[289, uint8]
    chanType*: uint8

  ApmStartInfoView {.packed.} = object
    staRateSeed*: array[13, uint8]
    reserved13*: array[19, uint8]
    beaconTemplate*: pointer
    beaconLength*: uint16
    timOffset*: uint16
    beaconInterval*: uint16
    reserved42*: array[2, uint8]
    beaconRateInfo*: uint32
    vifBeaconInterval*: uint16
    csaOffset0*: uint8
    vifIdx*: uint8
    reserved52*: array[196, uint8]
    basicRateCount*: uint8
    basicRates*: array[1, uint8]

  ApmStartChannelView {.packed.} = object
    freq*: uint16
    band*: uint8
    reserved03*: uint8
    chanType*: uint8
    reserved05*: uint8
    primFreq*: uint16
    reserved08*: array[2, uint8]
    centerFreq*: uint16
    reserved12*: array[2, uint8]
    authType*: uint8

  ApmStartReqView {.packed.} = object
    staRateSeed*: array[13, uint8]
    reserved13*: uint8
    channel*: ApmStartChannelView
    flags*: uint8
    reserved1e*: array[6, uint8]
    beaconLength*: uint16
    beaconLenOut*: uint16
    beaconInterval*: uint16
    reserved42*: array[8, uint8]
    beaconFlags*: uint8
    vifIdx*: uint8
    beaconIntervalIndex*: uint8
    basicRates*: array[13, uint8]
    dtimPeriod*: uint8
    reserved43*: uint8
    supportedRatesLong*: array[34, uint8]
    htCapSsidLen*: uint8
    ssid*: array[65, uint8]
    cryptoType*: uint8
    securityIe*: array[1, uint8]

  MmBcnChangeReqPayload {.packed.} = object
    beaconTemplate*: pointer
    beaconLength*: uint16
    timOffset*: uint16
    csaOffset0*: uint8
    csaOffset1*: uint8
    reserved10*: array[2, uint8]
    beaconData*: array[1, uint8]

  ApmRxMgmtPrefixView {.packed.} = object
    reserved00*: array[7, uint8]
    staIdx*: uint8
    vifIdx*: uint8
    reserved09*: array[7, uint8]
    assocWord16*: uint32
    assocWord20*: uint32
    assocByte24*: uint8
    reserved25*: array[3, uint8]
    assocByte28*: uint8
    reserved29*: array[13, uint8]
    staMac*: array[6, uint8]
    reserved48*: array[8, uint8]
    reason*: uint16
    bodyLen*: uint16
    bodyPrefix*: array[7, uint8]

  ApmAssocStaAddIndPayload {.packed.} = object
    macAddr*: array[6, uint8]
    rateCount*: uint8
    rateBytes*: array[49, uint8]
    rateBitfield*: uint32
    translatedRate*: uint32
    flags*: uint32
    aid*: uint16
    reserved70*: array[2, uint8]
    status*: uint8
    vifIdx*: uint8
    reserved74*: array[2, uint8]
    assocWord16*: uint32
    assocWord20*: uint32
    assocByte24*: uint8
    assocByte28*: uint8
    reserved86*: array[2, uint8]

  ApmAssocStaAddIndHtOverlay {.packed.} = object
    reserved00*: array[20, uint8]
    capInfo*: uint16
    reserved22*: array[18, uint8]
    extendedCap*: uint16
    reserved42*: array[2, uint8]
    txBfCap*: uint32
    aselCap*: uint8

  MmTimerView {.packed.} = object
    link*: CoListHdr
    callback*: pointer
    env*: uint32
    expiry*: uint32

  ChanCtxtDefView {.packed.} = object
    band*: uint8
    chanType*: uint8
    primFreq*: uint16
    centerFreq1*: uint16
    centerFreq2*: uint16
    txPower*: uint8
    reserved*: uint8

  ChanCtxtView {.packed.} = object
    link*: CoListHdr
    channel*: ChanCtxtDefView
    invalidMarker*: uint8
    reserved15*: uint8
    schedSlot*: uint16
    opSlot*: uint16
    tbttSlot*: uint16
    status*: uint8
    idx*: uint8
    linkCount*: uint8
    altIdx*: uint8
    reserved26*: array[2, uint8]

  ChanScanPoolOverlay {.packed.} = object
    channel*: ChanCtxtDefView
    vifIdx*: uint8
    reserved99*: array[3, uint8]
    durationTicks*: uint16
    reserved104*: array[2, uint8]
    active*: uint8
    slot*: uint8
    reserved108*: uint8
    requestVifIdx*: uint8

  ChanRocOverlay {.packed.} = object
    vifIdx*: uint8
    reserved127*: array[3, uint8]
    durationTicks*: uint16
    reserved132*: array[2, uint8]
    stateLo*: uint8
    slot*: uint8
    reserved136*: uint8
    band*: uint8
    channel*: ChanCtxtDefView

  ChanTbttNodeView {.packed.} = object
    link*: CoListHdr
    targetTime*: uint32
    vifIdx*: uint8
    priority*: uint8
    state*: uint8
    reserved*: uint8

  VifChannelView {.packed.} = object
    next*: pointer
    flags*: uint32
    edcaRegs*: array[4, uint32]
    tbttTimer*: MmTimerView
    beaconTimeoutTimer*: MmTimerView
    currentBssid*: array[6, uint8]
    reserved62*: array[2, uint8]
    chanCtxt*: pointer
    tbttNode*: ChanTbttNodeView
    macAddr*: array[6, uint8]
    vifType*: uint8
    vifIdx*: uint8
    state*: uint8
    txPower*: int8
    maxTxPower*: int8
    psFlags*: uint8
    listenInterval*: uint16
    psOptions*: uint8
    psNullRetry*: uint8
    staIdx*: uint8
    reserved97*: array[3, uint8]
    psLastTime*: uint32
    uapsdBitmap*: uint8
    reserved105*: array[3, uint8]
    beaconTimeoutBase*: uint32
    beaconCrc*: uint32
    probeCount*: uint8
    reserved117*: array[3, uint8]
    tbttCount*: uint32
    beaconLossCount*: uint32
    beaconRxCount*: uint32
    beaconLossWindow*: uint32
    lastBeaconMacTime*: uint32
    keepAliveTimer*: MmTimerView
    reserved156*: array[16, uint8]
    securityTimer*: MmTimerView
    rssiLast*: int8
    rssiThreshold*: int8
    rssiHysteresis*: uint8
    rssiState*: uint8
    reserved192*: array[4, uint8]
    keyPsState*: uint32
    reserved200*: array[8, uint8]
    beaconTxDesc*: pointer
    reserved212*: array[92, uint8]
    beaconTxCallback*: pointer
    beaconTxCallbackArg*: pointer
    reserved312*: array[4, uint8]
    beaconBodyLength*: uint16
    timLength*: uint16
    timCount*: uint16
    apBeaconInterval*: uint16
    beaconDivisor*: uint8
    beaconCountdown*: uint8
    beaconEnabled*: uint8
    timCountdown*: uint8
    timMin*: uint8
    timMax*: uint8
    timFlags*: uint8
    reserved331*: array[3, uint8]
    psBaCounter*: uint8
    reserved335*: uint8
    apStartBeaconInterval*: uint16
    apChanSwitchPending*: uint8
    reserved339*: uint8
    postponedStaHead*: pointer
    reserved344*: array[36, uint8]
    bssid*: array[6, uint8]
    supportedRatesLong*: array[34, uint8]
    scanBand*: uint16
    reserved422*: array[2, uint8]
    operChan*: pointer
    channelFreqPair*: uint32
    beaconIntervalTu*: uint16
    capabilityInfo*: uint16
    basicRates*: array[13, uint8]
    reserved449*: array[3, uint8]
    wmmQosInfo*: uint8
    wmmAcFlags*: uint8
    reserved454*: array[2, uint8]
    edcaParams*: array[128, uint8]

  VifSecurityOverlay {.packed.} = object
    connected*: uint8
    reserved489*: array[3, uint8]
    rsnIePtr*: uint32
    rsnIeLen*: uint8
    cipher*: uint8
    groupCipher*: uint8
    pairwiseCipher*: uint8
    keyMgmtByte*: uint8
    reserved501*: array[3, uint8]
    keyMgmt*: uint32
    pmfCapable*: uint8
    pmfRequired*: uint8
    staKeySlots*: array[4, uint8]

  VifMachwKeyIndexOverlay {.packed.} = object
    reserved00*: array[172, uint8]
    primaryPairwise*: uint8
    secondaryPairwise*: uint8
    group*: uint8

  VifHtCapabilitiesOverlay {.packed.} = object
    capInfo*: uint16
    ampduParams*: uint8
    mcsSet*: array[16, uint8]
    reserved19*: uint8
    extCap*: uint16
    reserved22*: array[2, uint8]
    txBfCaps*: uint32
    aselCap*: uint8

  VifHtOperationOverlay {.packed.} = object
    flags*: uint16
    reserved478*: uint8
    secChan*: uint8
    chanWidth*: uint8

  VifApConfigOverlay {.packed.} = object
    edcaParams*: array[17, uint8]
    noiseFloor1*: int8
    noiseFloor2*: int8
    highestRateBit*: uint8
    reserved20*: array[2, uint8]
    authType*: uint8
    requestedAuthType*: uint8
    reserved24*: array[4, uint8]
    securityFlags*: uint32
    reserved32*: array[26, uint8]
    beaconInterval*: uint16
    aidBitmapFeatureLow*: uint16
    maxAssocRate*: uint16
    privacyFlag*: uint8
    ssidData*: UncheckedArray[uint8]

  KeyReplayCounterView {.packed.} = object
    pnLow*: uint32
    pnHigh*: uint32
    reserved8*: array[8, uint8]

  ReplayCounterWindowSlot {.packed.} = object
    reserved00*: array[8, uint8]
    valid*: uint32

  ReplayCounterStateView {.packed.} = object
    pnLow*: uint32
    pnHigh*: uint32
    slots*: array[2, ReplayCounterWindowSlot]

  VifKeySlotView {.packed.} = object
    replayCounters*: array[8, KeyReplayCounterView]
    pnLow*: uint32
    pnHigh*: uint32
    keyMaterial*: array[16, uint8]
    cipherType*: uint8
    staIdx*: uint8
    keyIdx*: uint8
    installed*: uint8
    hasRxPn*: uint8
    reserved157*: array[3, uint8]

  TkipMicKeyAreaView {.packed.} = object
    reserved0*: uint32
    scratch*: pointer
    reserved8*: array[16, uint8]
    keyMaterial*: array[8, uint8]

  RxMicWordsView {.packed.} = object
    lo*: uint32
    hi*: uint32

  VifKeyPointersView {.packed.} = object
    defaultKeyPtr*: uint32
    groupKeyPtr*: uint32
    flags*: uint32

  VifRxProtectedKeyTableOverlay {.packed.} = object
    reserved00*: array[528, uint8]
    slots*: UncheckedArray[VifKeySlotView]

  VifKeySlotTableOverlay {.packed.} = object
    reserved00*: array[528, uint8]
    slots*: UncheckedArray[VifKeySlotView]

  TxSecurityKeyListView {.packed.} = object
    pairwiseKey*: pointer

  VifAssocInfoOverlay {.packed.} = object
    reserved00*: array[38, uint8]
    ssidLen*: uint8
    ssidData*: array[49, uint8]
    basicRates*: array[13, uint8]
    reserved101*: array[3, uint8]
    modeByte104*: uint8
    reserved105*: array[31, uint8]
    securityFlags*: uint32
    reserved140*: array[4, uint8]
    rsnIePtr*: uint32
    rsnIeLen*: uint8

  SecMacRxIndView {.packed.} = object
    staIdx*: uint8
    reserved01*: uint8
    length*: uint16
    payload*: UncheckedArray[uint8]

  ApmTxDescPsView {.packed.} = object
    reserved0*: array[4, uint8]
    staPeer*: pointer
    reserved8*: array[31, uint8]
    staInstNbr*: uint8
    reserved40*: array[6, uint8]
    tid*: uint8
    deliveryPolicy*: uint8
    reserved48*: uint8
    subtype*: uint8
    postponeFlags*: uint16
    reserved52*: array[16, uint8]
    pendingCount*: uint16
    reserved70*: array[38, uint8]
    staDesc*: pointer

  HostTxDescView {.packed.} = object
    link*: CoListHdr
    descWord4*: uint32
    queueFirst*: pointer
    seqPassthrough*: uint16
    reserved14*: array[2, uint8]
    cfmDst*: pointer
    da*: array[6, uint8]
    sa*: array[6, uint8]
    frameLen*: uint16
    pnScratch*: array[6, uint8]
    reserved40*: array[2, uint8]
    seqAssigned*: uint16
    reserved44*: array[2, uint8]
    staIdx*: uint8
    vifIdx*: uint8
    hostVifType*: uint8
    staInfoIdx*: uint8
    reserved50*: array[2, uint8]
    bufferPtrs*: array[4, uint32]
    bufferLens*: array[4, uint32]
    pendingMacTime*: uint32
    policy*: pointer
    reserved92*: array[4, uint8]
    seqOut*: uint16
    hdrLen*: uint8
    qosExtLen*: uint8
    secTailLen*: uint8
    reserved101*: array[3, uint8]
    dmaLink*: pointer
    bufDesc*: pointer
    hwDesc*: pointer
    aggDescPtr*: uint32
    reserved120*: array[52, uint8]
    retryCount*: uint32
    lifetime*: uint32
    txFlags*: uint32
    reserved184*: array[4, uint8]
    aggDescStorage*: array[16, uint8]
    cfmStatus*: uint32
    callback*: pointer
    callbackArg*: pointer
    usedFlag*: uint8
    postponeFlag*: uint8
    retryFlag*: uint8

  HostTxHwDescView {.packed.} = object
    txConfirmDescPtr*: uint32
    magic*: uint32
    secondaryThdPtr*: uint32
    txHwReserved12*: uint32
    status*: uint32
    payloadStart*: uint32
    payloadEnd*: uint32
    frameLen*: uint32
    txHwReserved32*: uint32
    retryLimitControl*: uint32
    chainedThd*: pointer
    txHwReserved44*: uint32
    txHwReserved48*: uint32
    txHwReserved52*: uint32
    ackPolicyControl*: uint32
    controlFlags*: uint32
    confirmStatus*: uint32

  HostTxThdEntryView {.packed.} = object
    magic*: uint32
    next*: pointer
    payloadStart*: uint32
    payloadEnd*: uint32
    flags*: uint32

  HostTxThdConfirmView {.packed.} = object
    magic*: uint32
    next*: pointer
    payloadStart*: uint32
    confirmType*: uint16
    reserved14*: uint16
    flags*: uint32

  TxDumpRateDescView {.packed.} = object
    word0*: uint32
    word4*: uint32
    word8*: uint32
    word12*: uint32
    next*: pointer
    policy0*: array[4, uint32]
    policy1*: array[4, uint32]

  TxDumpBufferDescView {.packed.} = object
    word0*: uint32
    next*: pointer
    word8*: uint32

  HostTxMicScratchView {.packed.} = object
    magic*: uint32
    micLInit*: uint32
    dataPtr*: pointer
    endPtr*: pointer
    pending*: uint32
    data*: array[12, uint8]

  CfgApiElementEntryView {.packed.} = object
    id*: uint32
    subId*: uint16
    typeId*: uint16
    name*: pointer
    data*: pointer
    setHandler*: pointer
    reserved20*: array[8, uint8]

  HostTxLinkDescView {.packed.} = object
    reserved0*: uint32
    headerLen*: uint32
    reserved8*: array[64, uint8]
    headerThd*: HostTxThdEntryView
    payloadThd*: array[4, HostTxThdEntryView]
    reserved172*: array[84, uint8]
    rateTemplate*: array[52, uint8]
    ackPolicyControl*: uint32
    retryLimitControl*: uint32
    micScratch*: HostTxMicScratchView
    macHeader*: UncheckedArray[uint8]

  HostTxInternalLinkNodeView {.packed.} = object
    reserved0*: uint32
    headerLen*: uint32
    reserved8*: array[8, uint8]
    next*: pointer
    txDesc*: pointer
    reserved24*: array[48, uint8]
    headerThd*: HostTxThdEntryView
    payloadThd*: array[4, HostTxThdEntryView]
    reserved172*: array[84, uint8]
    rateTemplate*: array[52, uint8]
    ackPolicyControl*: uint32
    retryLimitControl*: uint32
    micScratch*: HostTxMicScratchView
    macHeader*: UncheckedArray[uint8]

  HostTxBufferedLinkView {.packed.} = object
    reserved0*: uint32
    headerLen*: uint32
    padLen*: uint32
    reserved12*: uint32
    next*: pointer
    txDesc*: pointer
    reserved24*: array[48, uint8]
    headerThd*: HostTxThdEntryView
    payloadThd*: array[4, HostTxThdEntryView]
    reserved172*: array[80, uint8]
    userIdx*: uint8
    reserved253*: array[3, uint8]
    rateTemplate*: array[52, uint8]
    ackPolicyControl*: uint32
    retryLimitControl*: uint32
    micScratch*: HostTxMicScratchView
    macHeader*: UncheckedArray[uint8]

  HostTxAuxWordsView {.packed.} = object
    rateConfig*: uint32
    navValue*: uint32

  HostTxRateTemplateView {.packed.} = object
    magic*: uint32
    ntxConfig*: uint32
    bwMask*: uint32
    pendingCount*: uint32
    policyWord*: uint32
    rateWord*: uint32
    retryRateControl0*: uint32
    retryRateControl1*: uint32
    retryRateControl2*: uint32
    txPower*: int32
    retryTxPowerControl0*: uint32
    retryTxPowerControl1*: uint32
    retryTxPowerControl2*: uint32

  TxBufferControlView {.packed.} = object
    magic*: uint32
    ntxConfig*: uint32
    bwMask*: uint32
    pendingCount*: uint32
    policyWord*: uint32
    rateWord*: uint32
    retryRateControl0*: uint32
    retryRateControl1*: uint32
    retryRateControl2*: uint32
    txPower*: int32
    retryTxPowerControl0*: uint32
    retryTxPowerControl1*: uint32
    retryTxPowerControl2*: uint32
    ackPolicyControl*: uint32
    retryLimitControl*: uint32

  TxlFrameDescSlotView {.packed.} = object
    desc*: HostTxDescView
    reserved219*: uint8

  TxlFrameLinkSlotView {.packed.} = object
    storage*: array[860, uint8]

  TxlFrameHwDescSlotView {.packed.} = object
    desc*: HostTxHwDescView
    reserved68*: array[4, uint8]

  TxlFrameHwCfmSlotView {.packed.} = object
    words*: array[5, uint32]

  TxlFramePayloadSlotView {.packed.} = object
    desc*: TxBufferControlView

  TxlBackupQueueView {.packed.} = object
    first*: pointer
    last*: pointer

  TxlBufferEnvView {.packed.} = object
    reserved00*: array[180, uint8]
    backupQueues*: array[5, TxlBackupQueueView]

  MacDataFrameHeaderView {.packed.} = object
    frameControl*: uint16
    duration*: uint16
    addr1*: array[6, uint8]
    addr2*: array[6, uint8]
    addr3*: array[6, uint8]
    seqCtrl*: uint16

  MacQosDataFrameHeaderView {.packed.} = object
    data*: MacDataFrameHeaderView
    qosCtrl*: uint16

  MacQos4AddrFrameHeaderView {.packed.} = object
    data*: MacDataFrameHeaderView
    addr4*: array[6, uint8]
    qosCtrl*: uint16

  MacCtsFrameHeaderView {.packed.} = object
    frameControl*: uint16
    duration*: uint16
    receiverAddr*: array[6, uint8]

  PsPollFrameHeaderView {.packed.} = object
    frameControl*: uint16
    aid*: uint16
    bssid*: array[6, uint8]
    transmitterAddr*: array[6, uint8]

  SaQueryActionBodyView {.packed.} = object
    category*: uint8
    action*: uint8
    transId*: uint16

  TxSecurityHeaderView {.packed.} = object
    w0*: uint16
    w1*: uint16
    w2*: uint16
    w3*: uint16

  TxPnScratchView {.packed.} = object
    lo*: uint16
    mid*: uint16
    hi*: uint16

  LlcSnapHeaderView {.packed.} = object
    dsap*: uint8
    ssap*: uint8
    control*: uint8
    oui*: array[3, uint8]
    ethertype*: uint16

  MacFrameControlView {.packed.} = object
    frameControl*: uint16

  RxMsduSnapView {.packed.} = object
    snap*: LlcSnapHeaderView
    payload*: UncheckedArray[uint8]

  TxFrameBuildLayout = object
    mac*: ptr MacQosDataFrameHeaderView
    sec*: ptr TxSecurityHeaderView
    snap*: ptr LlcSnapHeaderView
    macLen*: uint8
    secLen*: uint8
    snapLen*: uint8

  TxPolicyView {.packed.} = object
    status*: uint32
    bufferAddr*: uint32
    bufferMask*: uint32
    packetType*: uint32
    controlInfo*: uint32
    retryRate*: array[4, uint32]
    txPower*: array[4, uint32]
    edcaParam0*: uint32
    edcaParam1*: uint32

  MichaelMicContextView {.packed.} = object
    left*: uint32
    right*: uint32
    pending*: uint32
    nBytes*: uint8
    reserved13*: array[3, uint8]

  StaInfoView {.packed.} = object
    link*: CoListHdr
    macAddr*: array[6, uint8]
    reserved10*: array[2, uint8]
    registerWord0*: uint32
    registerWord1*: uint32
    connectionStart*: uint32
    initialRateConfig*: uint32
    vif*: pointer
    rateSet*: uint16
    listenWindowDuration*: uint16
    aid*: uint16
    phyBwMax*: uint8
    instNbr*: uint8
    infoIdx*: uint8
    psMode*: uint8
    valid*: uint8
    extFlag*: uint8
    paramFlag*: uint8
    reserved45*: array[3, uint8]
    psStatus*: uint32
    beaconTimeOffset*: uint32
    reserved56*: array[14, uint8]
    rateWord*: uint16
    rxNss*: uint8
    trafficFlags*: uint8
    reserved74*: array[6, uint8]
    keyArea*: array[128, uint8]
    pnLow*: uint32
    pnHigh*: uint32
    keyTail*: array[16, uint8]
    keyType*: uint8
    cipherSuite*: uint8
    hwKeyIdx*: uint8
    keyInstalled*: uint8
    keyFlags*: uint8
    reserved237*: array[3, uint8]
    keyHolder*: pointer
    keyMat*: pointer
    supportedRates*: array[13, uint8]
    reserved261*: array[3, uint8]
    vhtCaps*: array[32, uint8]
    reserved296*: array[12, uint8]
    capabilityFlags*: uint32
    bwConfigState*: uint8
    nssBwMax*: uint8
    psState*: uint8
    uapsdBitmap*: uint8
    htVhtConfig*: uint8
    reserved317*: array[3, uint8]
    txPolicy*: pointer
    rcStats*: pointer
    aggregationLength*: uint32
    supportedRatesBitmap*: uint16
    mmFlagsBytes*: array[4, uint8]
    reserved338*: array[18, uint8]
    postponedList*: CoList
    apmConnectTime*: uint32

  StaBandwidthOverlay {.packed.} = object
    rateInfoPtr*: pointer
    primaryBw*: uint16
    bwField*: uint16
    reserved84*: array[46, uint8]
    secondaryBw*: uint16

  StaTxSequenceOverlay {.packed.} = object
    reserved00*: array[28, uint8]
    seqCounter*: uint16

  RxuQosSeqCacheEntryView {.packed.} = object
    seqCtrl*: uint16
    reserved02*: array[182, uint8]

  RxuQosSeqCacheTableOverlay {.packed.} = object
    reservedBefore*: array[169 * 184, uint8]
    entries*: UncheckedArray[RxuQosSeqCacheEntryView]

  ApSelfStaStartOverlay {.packed.} = object
    reserved00*: array[4, uint8]
    status*: uint16
    reserved06*: array[34, uint8]
    infoIdx*: uint8
    reserved41*: uint8
    valid*: uint8
    reserved43*: array[29, uint8]
    vifType*: uint8
    reserved73*: array[175, uint8]
    rateSeed*: array[13, uint8]
    reserved261*: array[73, uint8]
    rcFlags*: uint8

  StaMgmtRegisterParamView {.packed.} = object
    vif*: pointer
    rateSet*: uint16
    macAddr*: array[6, uint8]
    phyBwMax*: uint8
    instNbr*: uint8
    extFlag*: uint8
    reserved15*: uint8
    registerWord0*: uint32
    registerWord1*: uint32
    paramFlag*: uint8

  ChanEnvView {.packed.} = object
    freeList*: CoList
    activeList*: CoList
    tbttSwitchList*: CoList
    tbttList*: CoList
    currentCtxt*: pointer
    scheduledCtxt*: pointer
    scanCtxt*: pointer
    reserved44*: uint32
    tbttSwitchCallback*: pointer
    tbttDeferredSlot*: pointer
    reserved56*: array[8, uint8]
    cdeCallback*: pointer
    cdeArg*: pointer
    nextChanTimestamp*: uint32
    reserved76*: array[4, uint8]
    ctxtOpCallback*: pointer
    reserved84*: array[4, uint8]
    remainingTimeTarget*: uint32
    reserved92*: array[4, uint8]
    connLessDelayCallback*: pointer
    reserved100*: array[4, uint8]
    timerState*: uint8
    reserved105*: array[3, uint8]
    slotPeriod*: uint32
    lastMacTime*: uint32
    cdeStarted*: uint32
    flags*: uint8
    scanDelayCount*: uint8
    connlessDelayCount*: uint8
    switchPending*: uint8
    ctxtCount*: uint8
    schedState*: uint8
    surveySnapshot*: uint8
    reserved127*: uint8
    deferredMsg*: pointer

  RxuCntrlEnvView {.packed.} = object
    frameCtrl*: uint16
    seqCtrl*: uint16
    seqNum*: uint16
    fragNum*: uint8
    tid*: uint8
    machdrLen*: uint8
    staIdx*: uint8
    vifIdx*: uint8
    dstIdx*: uint8
    reserved12*: array[4, uint8]
    secInfo0*: uint32
    secInfo1*: uint32
    hwRxhdr*: uint32
    reserved28*: uint32
    secKeyPtr*: pointer
    da*: array[6, uint8]
    sa*: array[6, uint8]
    secFlags*: uint8
    meshFlag*: uint8
    stripLen*: uint8
    reserved51*: array[5, uint8]
    deferredList*: CoList
    uploadList*: CoList
    pendingList*: CoList
    freeList*: CoList
    reserved88*: array[6, uint8]
    bssidSeq*: uint16

  CcmpSecurityHeaderView {.packed.} = object
    pn0*: uint8
    pn1*: uint8
    reserved2*: uint8
    keyId*: uint8
    pn2*: uint8
    pn3*: uint8
    pn4*: uint8
    pn5*: uint8

  TkipSecurityHeaderView {.packed.} = object
    tsc1*: uint8
    wepSeed*: uint8
    tsc0*: uint8
    keyId*: uint8
    tsc2*: uint8
    tsc3*: uint8
    tsc4*: uint8
    tsc5*: uint8

  RxlCntrlEnvView {.packed.} = object
    queue*: CoList
    submittedHead*: pointer
    submittedTail*: pointer
    currentHd*: pointer
    pendingMpduCount*: uint32
    processingFlag*: uint8
    reserved25*: array[3, uint8]

  RxHwDescEnvView {.packed.} = object
    pdTail*: pointer
    pdCurrent*: pointer

  RxHeaderHwDescView {.packed.} = object
    magic*: uint32
    next*: pointer
    bufferAddr*: uint32
    swDesc*: uint32
    nextThd*: uint32
    status*: uint32
    rxStatusWord24*: uint32
    statusHalf*: uint16
    statusHalf2*: uint16
    rxVectorWord32*: uint32
    rxVectorWord36*: uint32
    reserved40*: uint32
    word44*: uint32
    rxVectorWord48*: uint32
    rxVectorWord52*: uint32
    rxVectorWord56*: uint32
    rxVectorWord60*: uint32
    flags*: uint32
    reserved68*: array[28, uint8]
    usedFlag*: uint32

  RxSwTableDescView {.packed.} = object
    reserved00*: uint32
    firstHeaderDesc*: pointer
    reserved08*: array[16, uint8]

  RxSwDescView {.packed.} = object
    reserved00*: uint32
    firstDmaDesc*: pointer
    bufferChain*: pointer
    reserved12*: array[16, uint8]
    payloadLenHalf*: uint16
    reserved30*: array[2, uint8]
    timestampLow*: uint32
    timestampHigh*: uint32
    phyVector*: array[24, uint8]
    hwFlags*: uint32
    channelInfo*: array[8, uint8]
    frameControlFlags*: uint32
    reserved80*: array[4, uint8]
    bufferOffset*: uint32
    reserved88*: array[8, uint8]
    uploadDone*: uint32

  RxMpduDescView {.packed.} = object
    reserved00*: uint32
    swDesc*: pointer
    reserved08*: uint32
    prevDesc*: pointer
    curDesc*: pointer
    descFlag*: uint8
    descCount*: uint8

  RxPayloadHwDescView {.packed.} = object
    magic*: uint32
    next*: pointer
    bufferAddr*: uint32
    bufferEnd*: uint32
    status*: uint32
    usedFlag*: uint32
    bufferStart*: uint32
    frameLen*: uint16
    reserved30*: array[22, uint8]

  RxPayloadBufferView {.packed.} = object
    bytes*: array[1736, uint8]

  RxFrameBufferRefView {.packed.} = object
    reserved00*: array[24, uint8]
    frameData*: pointer

  RxFrameBufferChainView {.packed.} = object
    reserved00*: uint32
    next*: pointer
    frameData*: pointer

  RxDmaProgressDescView {.packed.} = object
    reserved00*: uint32
    next*: pointer
    reserved08*: array[8, uint8]
    status*: uint16
    reserved18*: uint16
    usedFlag*: uint32

  RxMicFailureIndView {.packed.} = object
    bssid*: array[6, uint8]
    reserved06*: array[2, uint8]
    pnLow*: uint32
    pnHigh*: uint32
    tid*: uint8
    keyType*: uint8
    vifIdx*: uint8
    hwRxhdrHigh*: uint8
    reserved20*: uint32

  RxEthernetRewriteHeaderView {.packed.} = object
    da*: array[6, uint8]
    sa*: array[6, uint8]
    ethertype*: uint16

  RxuMgtIndMsgView {.packed.} = object
    frameLen*: uint16
    frameCtrl*: uint16
    freq*: uint16
    band*: uint8
    vifIdx*: uint8
    rxuVifIdx*: uint8
    reserved09*: array[7, uint8]
    timestampLow*: uint32
    timestampHigh*: uint32
    phyVector11*: uint8
    rssi*: int8
    noiseFloor*: int8
    secondary*: uint8
    phyVector0*: uint8
    reserved29*: array[3, uint8]
    body*: UncheckedArray[uint8]

  RxUploadDmaArrayView {.packed.} = object
    bufferAddrs*: array[4, uint32]
    reserved16*: array[16, uint8]
    lengths*: array[4, uint16]

  RxuUploadEnvView {.packed.} = object
    reserved00*: array[20, uint8]
    uploadCount*: uint32
    reserved24*: uint32

  RxlHwdescCallbackEnvView {.packed.} = object
    reserved00*: array[20, uint8]
    getStatus*: pointer
    clean*: pointer

  RxlSubmittedDescView {.packed.} = object
    reserved00*: uint32
    next*: pointer
    bufferChain*: pointer
    swDesc*: pointer
    reserved16*: array[48, uint8]
    status*: uint32

  BeaconRxDescView {.packed.} = object
    reserved00*: array[8, uint8]
    payloadDesc*: pointer
    reserved12*: array[16, uint8]
    frameLen*: uint16
    reserved30*: array[21, uint8]
    rssi*: int8

  BeaconPayloadDescView {.packed.} = object
    reserved00*: array[8, uint8]
    frameData*: pointer

  BeaconFrameFixedView {.packed.} = object
    frameControl*: uint16
    duration*: uint16
    addr1*: array[6, uint8]
    addr2*: array[6, uint8]
    addr3*: array[6, uint8]
    seqCtrl*: uint16
    tsfLow*: uint32
    tsfHigh*: uint32
    beaconInterval*: uint16
    capabilityInfo*: uint16
    body*: UncheckedArray[uint8]

  ProbeRspFixedBodyView {.packed.} = object
    tsfLow*: uint32
    tsfHigh*: uint32
    beaconInterval*: uint16
    capabilityInfo*: uint16
    body*: UncheckedArray[uint8]

  HtMcsNssPrefixView {.packed.} = object
    nss0*: uint8
    nss1*: uint8
    nss2*: uint8
    nss3*: uint8

  CoDlistHdr* = object
    next*: ptr CoDlistHdr
    prev*: ptr CoDlistHdr

  CoDlist* = object
    first*: ptr CoDlistHdr
    last*: ptr CoDlistHdr
    cnt*: uint32

  CoPoolNode* = object
    next*: ptr CoPoolNode
    data*: pointer

  CoPool* = object
    first*: ptr CoPoolNode  ## Head of free node chain
    cnt*: uint32            ## Number of free nodes

# Kernel message header (12 bytes before payload, matching ke_msg_alloc layout)
type
  KeMsgHdr* = object
    next*: ptr KeMsgHdr     # link pointer (offset 0)
    id*: uint16             # message ID (offset 4)
    destId*: uint8          # destination task (offset 6)
    srcId*: uint8           # source task (offset 7)
    paramLen*: uint32       # parameter length (offset 8)
    # payload follows at offset 12

  KeMsgEnvelope* {.packed.} = object
    header*: KeMsgHdr
    payload*: UncheckedArray[uint8]

  MmVersionCfmPayload {.packed.} = object
    fwVersion*: uint32
    hwVersion0*: uint32
    hwVersion1*: uint32
    phyVersion0*: uint32
    phyVersion1*: uint32
    features*: uint32

  MmStartReqPayload {.packed.} = object
    band*: uint8
    chanType*: uint8
    prim20Freq*: uint16
    center1Freq*: uint16
    center2Freq*: uint16
    txPower*: uint8

  MmAddIfCfmPayload {.packed.} = object
    status*: uint8
    vifIdx*: uint8

  MmAddIfReqPayload {.packed.} = object
    ifType*: uint8
    macAddr*: array[6, uint8]
    p2p*: uint8

  MmRemoveIfReqPayload {.packed.} = object
    vifIdx*: uint8

  MmConnectionLossIndPayload {.packed.} = object
    reason*: uint16
    vifIdx*: uint8
    reserved*: uint8

  MmPsChangeIndPayload {.packed.} = object
    staIdx*: uint8
    psState*: uint8

  MmSetPsOptionsReqPayload {.packed.} = object
    vifIdx*: uint8
    reserved0*: uint8
    listenInterval*: uint16
    options*: uint8
    reserved1*: uint8

  MmSetIdleReqPayload {.packed.} = object
    idle*: uint8

  MmSetBssidReqPayload {.packed.} = object
    bssid*: array[6, uint8]
    vifIdx*: uint8

  MmSetBeaconIntReqPayload {.packed.} = object
    interval*: uint16
    vifIdx*: uint8
    reserved*: uint8

  MmSetBasicRatesReqPayload {.packed.} = object
    rateBitfield*: uint32
    vifIdx*: uint8
    band*: uint8
    reserved*: array[2, uint8]

  MmSetEdcaReqPayload {.packed.} = object
    edcaParam*: uint32
    uapsdAc*: uint8
    acmFlag*: uint8
    vifIdx*: uint8
    reserved*: uint8

  MmSetVifStateReqPayload {.packed.} = object
    aid*: uint16
    state*: uint8
    vifIdx*: uint8

  MmSetChannelReqPayload {.packed.} = object
    band*: uint8
    chanType*: uint8
    prim20Freq*: uint16
    center1Freq*: uint16
    center2Freq*: uint16
    index*: uint8
    txPower*: uint8

  MmSetChannelCfmPayload {.packed.} = object
    status*: uint8
    reserved*: uint8

  MeAddBaReqParamView {.packed.} = object
    reserved00*: array[8, uint8]
    ssn*: uint16
    timeout*: uint16
    reserved12*: array[2, uint8]
    amsduSupported*: uint8
    bufferSize*: uint8
    tid*: uint8
    dialogToken*: uint8

  AddBaReqActionBodyView {.packed.} = object
    category*: uint8
    action*: uint8
    dialogToken*: uint8
    baParams*: uint16
    timeout*: uint16
    startSeq*: uint16

  AddBaRspActionBodyView {.packed.} = object
    category*: uint8
    action*: uint8
    dialogToken*: uint8
    statusCode*: uint16
    baParams*: uint16
    timeout*: uint16

  DelBaActionBodyView {.packed.} = object
    category*: uint8
    action*: uint8
    delbaParams*: uint16
    reasonCode*: uint16

  DelBaInfoView {.packed.} = object
    reserved00*: array[13, uint8]
    initiator*: uint8
    reserved14*: array[2, uint8]
    tid*: uint8

  SmAuthFrameView {.packed.} = object
    frameLen*: uint16
    reserved02*: array[30, uint8]
    authAlgo*: uint16
    authSeq*: uint16
    statusCode*: uint16
    saeBodyFirst*: uint8
    reserved39*: uint8
    sharedChallengeFirst*: uint8

  SmAssocRspFrameView {.packed.} = object
    frameLen*: uint16
    reserved02*: array[30, uint8]
    capabilityInfo*: uint16
    statusCode*: uint16
    aid*: uint16
    iesFirst*: uint8

  AuthFixedBodyView {.packed.} = object
    authAlgo*: uint16
    authSeq*: uint16
    statusCode*: uint16

  AuthBodyTraceView {.packed.} = object
    fixed*: AuthFixedBodyView
    challengeTag*: uint8
    challengeLen*: uint8

  AuthChallengeBodyView {.packed.} = object
    fixed*: AuthFixedBodyView
    challengeTag*: uint8
    challengeLen*: uint8
    challengeText*: array[128, uint8]

  AuthBodyDataView {.packed.} = object
    fixed*: AuthFixedBodyView
    data*: UncheckedArray[uint8]

  ManagementReasonBodyView {.packed.} = object
    reason*: uint16

  AssocReqFixedBodyView {.packed.} = object
    capabilityInfo*: uint16
    listenInterval*: uint16
    reassocBssid*: array[6, uint8]

  AssocRspFixedBodyView {.packed.} = object
    capabilityInfo*: uint16
    statusCode*: uint16
    aid*: uint16

  SmDeauthFrameView {.packed.} = object
    reserved00*: array[7, uint8]
    saQueryVifIdx*: uint8
    vifIdx*: uint8
    reserved09*: array[18, uint8]
    frameFlags*: uint8
    reserved28*: array[8, uint8]
    sa*: array[6, uint8]
    reserved42*: array[6, uint8]
    bssid*: array[6, uint8]
    reserved54*: array[2, uint8]
    reason*: uint16

  MfpMgmtFramePolicyView {.packed.} = object
    frameCtrl*: uint16
    reserved02*: array[6, uint8]
    bodyOffset*: uint8
    staIdx*: uint8
    vifIdx*: uint8
    reserved11*: array[25, uint8]
    flags*: uint8

  RxuMgtDispatchView {.packed.} = object
    reserved00*: array[2, uint8]
    frameCtrl*: uint16
    reserved04*: array[3, uint8]
    staIdx*: uint8
    traceByte8*: uint8
    reserved09*: array[23, uint8]
    category*: uint8
    actionCode*: uint8
    dialogToken*: uint8
    baParam*: uint16

  SmSaQueryFrameView {.packed.} = object
    reserved00*: array[7, uint8]
    staIdx*: uint8
    vifIdx*: uint8
    reserved09*: array[24, uint8]
    action*: uint8
    transId*: uint16

  MmStaAddCfmPayload {.packed.} = object
    status*: uint8
    staIdx*: uint8
    hwStaIdx*: uint8

  MmStaAddReqPayload {.packed.} = object
    reserved0*: uint32
    rateMask*: uint16
    bssid*: array[6, uint8]
    bw*: uint8
    vifIdx*: uint8
    reserved1*: array[11, uint8]
    quickConn*: uint8
    reserved2*: uint16

  MmStaDelReqPayload {.packed.} = object
    staIdx*: uint8

  MmSetPsModeReqPayload {.packed.} = object
    mode*: uint8

  MmRssiStatusIndPayload {.packed.} = object
    vifIdx*: uint8
    value1*: uint8
    value2*: uint8

  MmPrimaryTbttIndPayload {.packed.} = object
    staIdx*: uint8
    reserved0*: uint8
    reserved1*: uint8

  MmRemainOnChannelCfmPayload {.packed.} = object
    vifIdx*: uint8
    status*: uint8
    reqType*: uint8

  MmRemainOnChannelReqPayload {.packed.} = object
    vifIdx*: uint8

  MmTimUpdatePayload {.packed.} = object
    aid*: uint16
    setFlag*: uint8
    vifIdx*: uint8

  MmChanCtxtUpdatePayload {.packed.} = object
    ctxtIdx*: uint8
    reserved0*: uint8
    band*: uint8
    secChan*: uint8
    primFreq*: uint16
    centerFreq1*: uint16
    centerFreq2*: uint16
    txPower*: uint8
    reserved1*: uint8

  ChanConnLessDelayReqPayload {.packed.} = object
    remainingCount*: uint8
    band*: uint8
    reserved0*: uint16
    durationMs*: uint32
    chanDef*: array[10, uint8]
    reserved1*: uint16

  MeSetPsDisableReqPayload {.packed.} = object
    disable*: uint8
    vifIdx*: uint8

  MeSetActiveReqPayload {.packed.} = object
    active*: uint8
    vifIdx*: uint8

  MeStaDelReqPayload {.packed.} = object
    staIdx*: uint8

  MeStaAddCfmPayload {.packed.} = object
    staIdx*: uint8
    status*: uint8
    reserved*: array[6, uint8]

  MeConfigReqPayload {.packed.} = object
    htCaps*: array[32, uint8]
    reserved32*: array[12, uint8]
    defKey*: uint16
    htSupp*: uint8
    reserved47*: uint8
    psOn*: uint8

  MeStaAddReqPayload {.packed.} = object
    macAddr*: array[6, uint8]
    supportedRates*: array[13, uint8]
    reserved19*: uint8
    capBlockHead*: array[2, uint8]
    htCapInfo*: uint16
    capBlockTail*: array[28, uint8]
    reserved52*: array[12, uint8]
    capFlags*: uint8
    reserved65*: array[3, uint8]
    beaconInterval*: uint16
    uapsd0*: uint8
    uapsd1*: uint8
    reserved72*: uint8
    staIdx*: uint8

  MeRcSetRateReqPayload {.packed.} = object
    staIdx*: uint8
    reserved*: uint8
    fixedRate*: uint16
    mcsRate*: uint16

  MeTrafficIndReqPayload {.packed.} = object
    staIdx*: uint8
    uapsd*: uint8
    txAvail*: uint8

  ApmStartCfmPayload {.packed.} = object
    status*: uint8
    vifIdx*: uint8
    band*: uint8
    staIdx*: uint8

  ApmStopReqPayload {.packed.} = object
    vifIdx*: uint8

  ApmStaDelReqPayload {.packed.} = object
    vifLookupIdx*: uint8
    staIdxInVif*: uint8

  ApmStaDelCfmPayload {.packed.} = object
    status*: uint8
    reserved*: array[3, uint8]

  ApmStaAddCfmParamView {.packed.} = object
    staIdx*: uint8

  ApmStaDelIndPayload {.packed.} = object
    reason*: uint16
    extra*: uint16
    staIdx*: uint8
    reserved*: uint8

  ApmStaAddIndPayload {.packed.} = object
    rateConfig*: uint32
    macLow*: uint32
    macHigh*: uint16
    vifInst*: uint8
    infoIdx*: uint8
    capability*: uint8
    reserved0*: array[3, uint8]
    assoc0*: uint32
    assoc1*: uint32
    flags*: uint8
    reserved1*: array[3, uint8]

  ApmConfMaxStaReqPayload {.packed.} = object
    maxSta*: uint8

  ApmProbeReqView {.packed.} = object
    bodyLen*: uint16
    reserved02*: array[6, uint8]
    vifIdx*: uint8
    reserved09*: array[33, uint8]
    staMac*: array[6, uint8]

  StaKeyReqPayload {.packed.} = object
    cipherSuite*: uint8
    reserved01*: array[23, uint8]
    keyDataPrefix*: array[28, uint8]
    keyType*: uint8
    keyDataTail*: array[2, uint8]
    keyFlags*: uint8

  MachwKeyWriteParamView {.packed.} = object
    addrIdx*: uint8
    keyType*: uint8
    reserved02*: array[2, uint8]
    keyLen*: uint8
    reserved05*: array[3, uint8]
    keyWords*: array[4, uint32]
    reserved24*: array[16, uint8]
    macLen*: uint8
    reserved41*: array[3, uint8]
    macAddr*: array[6, uint8]
    reserved50*: array[2, uint8]
    cipherType*: uint8
    keyIdx*: uint8
    spp*: uint8
    keyFlags*: uint8

  IgtkKeyWriteStackView {.packed.} = object
    reserved00*: array[39, uint8]
    resultByte*: uint8
    req*: MachwKeyWriteParamView

  SupplicantKeyParamView {.packed.} = object
    addrIdx*: uint8
    keyType*: uint8
    reserved02*: array[2, uint8]
    keyLen*: uint8
    reserved05*: array[3, uint8]
    keyData*: array[32, uint8]
    macLen*: uint8
    reserved41*: array[3, uint8]
    macAddr*: array[8, uint8]
    translatedCipher*: uint8
    keyIdx*: uint8
    spp*: uint8
    rawCipher*: uint8

  SupplicantTkipKeyDataView {.packed.} = object
    temporalKey*: array[16, uint8]
    micTx*: array[2, uint32]
    micRx*: array[2, uint32]

  VifMgmtAddKeyParamView {.packed.} = object
    staIdx*: uint8
    keyType*: uint8
    reserved02*: array[2, uint8]
    keyLen*: uint8
    reserved05*: array[3, uint8]
    ccmpKeyMaterial*: array[16, uint8]
    tkipKeyMaterial*: array[16, uint8]
    macLen*: uint8
    reserved41*: array[3, uint8]
    pnLowBytes*: array[4, uint8]
    pnHighBytes*: array[4, uint8]
    cipherType*: uint8
    keySlot*: uint8
    spp*: uint8
    hasRxPn*: uint8
    reserved52*: array[4, uint8]

  ScanuRawSendCfmPayload {.packed.} = object
    result*: uint32

  ScanuRawSendReqPayload {.packed.} = object
    framePtr*: pointer
    frameLen*: uint32

  SmConnectAuthAssocReqPayload {.packed.} = object
    nextState*: uint16
    param1*: uint16
    param2*: uint32

  SmConnectIndPayload {.packed.} = object
    statusCode*: uint16
    reasonCode*: uint16
    bssid*: array[6, uint8]
    securityStatus*: uint8
    vifIdx*: uint8
    aid*: uint8
    channelStatus*: uint8
    hasWmm*: uint8
    qosFlag*: uint8
    assocReqIeLen*: uint16
    assocRspIeLen*: uint16
    assocIeBuffer*: array[800, uint8]
    reserved820*: array[2, uint8]
    chanBand*: uint8
    reserved823*: uint8
    chanPrimFreq*: uint16
    chanType*: uint8
    reserved827*: uint8
    chanCenterFreq1*: uint32
    chanCenterFreq2*: uint32

  SmVifIdxReqPayload {.packed.} = object
    vifIdx*: uint8

  MmMonitorReqPayload {.packed.} = object
    channel*: uint32

  MmMonitorCfmPayload {.packed.} = object
    status*: uint32
    channel*: uint32
    reserved*: uint32
    debug1*: uint32
    debug2*: uint32
    debug3*: uint32
    debug4*: uint32
    debug5*: uint32
    debug6*: uint32
    debug7*: uint32

  StatusCfmPayload {.packed.} = object
    status*: uint8

  Status4CfmPayload {.packed.} = object
    status*: uint8
    reserved*: array[3, uint8]

  SmDisconnectIndPayload {.packed.} = object
    status*: uint16
    reason*: uint16
    vifIdx*: uint8
    ftOverDs*: uint8
    reserved*: array[2, uint8]
    diagnoseFirst*: pointer

  SmDisconnectProcessIndPayload {.packed.} = object
    status*: uint16
    reason*: uint16
    vifIdx*: uint8
    reserved*: array[11, uint8]

  SmDisconnectReasonPayload {.packed.} = object
    reason*: uint16

  SmStaAddIndPayload {.packed.} = object
    vifIdx*: uint8
    staIdx*: uint8
    wpa*: uint8

  RcRetryChainParamPayload {.packed.} = object
    throughput*: uint32

  MeTrafficIndCfmPayload {.packed.} = object
    aid*: uint16
    uapsd*: uint8
    instNbr*: uint8

  MmStaDelKeyCfmPayload {.packed.} = object
    hwKeyIdx*: uint8
    status*: uint8

  BamTrafficStatusPayload {.packed.} = object
    staIdx*: uint8
    tid*: uint8
    status*: uint8
    reserved*: array[53, uint8]

  IpcEmbMsgDescView {.packed.} = object
    id*: uint16
    dstId*: uint8
    srcId*: uint8
    paramLen*: uint32

  IpcEmbMsgEnvelopeView {.packed.} = object
    desc*: IpcEmbMsgDescView
    payload*: UncheckedArray[uint8]

  IpcSharedMsgView {.packed.} = object
    reserved0*: array[4, uint8]
    id*: uint16
    dstId*: uint8
    srcId*: uint8
    paramLen*: uint32
    payload*: UncheckedArray[uint8]

  IpcPayloadWordStreamView {.packed.} = object
    words*: UncheckedArray[uint32]

  IpcSharedEnvView {.packed.} = object
    reserved0*: array[4, uint8]
    id*: uint16
    dstId*: uint8
    srcId*: uint8
    paramLen*: uint32
    payloadArea*: array[0x24CC - 12, uint8]
    hostTxListCursor*: CoList
    hostTxCfmCursor*: CoList

  IpcEmbEnvView {.packed.} = object
    counter*: uint8
    reserved1*: array[11, uint8]
    hostTxList*: ptr CoList
    hostTxCfmList*: ptr CoList

  IpcHostTxWrapperView {.packed.} = object
    link*: CoListHdr
    reserved4*: uint32
    active*: uint32
    txDesc*: HostTxDescView

  IpcTxAcDescView {.packed.} = object
    descriptor*: uint32
    descPtr*: uint32
    reserved8*: array[4, uint8]
    sequence*: uint16
    busy*: uint8
    reserved15*: uint8

  IpcTxHwDescWordTableView {.packed.} = object
    descriptorWords*: array[NUM_TX_QUEUES, uint32]

  ScanChannelEntry {.packed.} = object
    prim20Freq*: uint16
    band*: uint8
    flags*: uint8
    txPower*: int8
    reserved*: uint8

  ScanSsidSlotView {.packed.} = object
    length*: uint8
    data*: array[33, uint8]

  ScanStartReqPayload {.packed.} = object
    channelList*: array[42, ScanChannelEntry]
    ssidFilter*: array[34, uint8]
    bssid*: array[6, uint8]
    localMac*: array[6, uint8]
    reserved0*: uint16
    scanResult*: uint32
    ieBodyLen*: uint16
    vifIdx*: uint8
    channelCount*: uint8
    scanType*: uint8
    passive*: uint8
    sendProbe*: uint8
    reserved1*: uint8
    addIeLen*: uint32

  ScanuStartReqPayload {.packed.} = object
    channelList*: array[42, ScanChannelEntry]
    ssidFilter*: array[34, uint8]
    bssid*: array[6, uint8]
    localMac*: array[6, uint8]
    reserved0*: uint16
    probeReqIe*: pointer
    probeReqIeLen*: uint16
    vifIdx*: uint8
    channelCount*: uint8
    scanType*: uint8
    passive*: uint8
    reserved1*: uint16
    flags*: uint32
    addIeLen*: uint32

const KeMsgHdrSize* = sizeof(KeMsgHdr).uint
const
  MmVersionCfmPayloadSize = sizeof(MmVersionCfmPayload).uint32
  MmStartReqPayloadSize = sizeof(MmStartReqPayload).uint32
  MmAddIfCfmPayloadSize = sizeof(MmAddIfCfmPayload).uint32
  MmAddIfReqPayloadSize = sizeof(MmAddIfReqPayload).uint32
  MmRemoveIfReqPayloadSize = sizeof(MmRemoveIfReqPayload).uint32
  MmConnectionLossIndPayloadSize = sizeof(MmConnectionLossIndPayload).uint32
  MmPsChangeIndPayloadSize = sizeof(MmPsChangeIndPayload).uint32
  MmSetPsOptionsReqPayloadSize = sizeof(MmSetPsOptionsReqPayload).uint32
  MmSetIdleReqPayloadSize = sizeof(MmSetIdleReqPayload).uint32
  MmSetBssidReqPayloadSize = sizeof(MmSetBssidReqPayload).uint32
  MmSetBeaconIntReqPayloadSize = sizeof(MmSetBeaconIntReqPayload).uint32
  MmSetBasicRatesReqPayloadSize = sizeof(MmSetBasicRatesReqPayload).uint32
  MmSetEdcaReqPayloadSize = sizeof(MmSetEdcaReqPayload).uint32
  MmSetVifStateReqPayloadSize = sizeof(MmSetVifStateReqPayload).uint32
  MmSetChannelReqPayloadSize = sizeof(MmSetChannelReqPayload).uint32
  MmSetChannelCfmPayloadSize = sizeof(MmSetChannelCfmPayload).uint32
  MmStaAddCfmPayloadSize = sizeof(MmStaAddCfmPayload).uint32
  MmStaAddReqPayloadSize = sizeof(MmStaAddReqPayload).uint32
  MmStaDelReqPayloadSize = sizeof(MmStaDelReqPayload).uint32
  MmSetPsModeReqPayloadSize = sizeof(MmSetPsModeReqPayload).uint32
  MmRssiStatusIndPayloadSize = sizeof(MmRssiStatusIndPayload).uint32
  MmPrimaryTbttIndPayloadSize = sizeof(MmPrimaryTbttIndPayload).uint32
  MmRemainOnChannelReqPayloadSize =
    sizeof(MmRemainOnChannelReqPayload).uint32
  MmRemainOnChannelCfmPayloadSize =
    sizeof(MmRemainOnChannelCfmPayload).uint32
  MmTimUpdatePayloadSize = sizeof(MmTimUpdatePayload).uint32
  MmChanCtxtUpdatePayloadSize = sizeof(MmChanCtxtUpdatePayload).uint32
  ChanConnLessDelayReqPayloadSize =
    sizeof(ChanConnLessDelayReqPayload).uint32
  MeSetPsDisableReqPayloadSize = sizeof(MeSetPsDisableReqPayload).uint32
  MeSetActiveReqPayloadSize = sizeof(MeSetActiveReqPayload).uint32
  MeStaDelReqPayloadSize = sizeof(MeStaDelReqPayload).uint32
  MeStaAddCfmPayloadSize = sizeof(MeStaAddCfmPayload).uint32
  MeConfigReqPayloadSize = sizeof(MeConfigReqPayload).uint32
  MeStaAddReqPayloadSize = sizeof(MeStaAddReqPayload).uint32
  MeRcSetRateReqPayloadSize = sizeof(MeRcSetRateReqPayload).uint32
  MeTrafficIndReqPayloadSize = sizeof(MeTrafficIndReqPayload).uint32
  ApmStartCfmPayloadSize = sizeof(ApmStartCfmPayload).uint32
  ApmStopReqPayloadSize = sizeof(ApmStopReqPayload).uint32
  ApmStaDelCfmPayloadSize = sizeof(ApmStaDelCfmPayload).uint32
  ApmStaDelIndPayloadSize = sizeof(ApmStaDelIndPayload).uint32
  ApmStaAddIndPayloadSize = sizeof(ApmStaAddIndPayload).uint32
  ApmConfMaxStaReqPayloadSize = sizeof(ApmConfMaxStaReqPayload).uint32
  ApmProbeReqViewSize = sizeof(ApmProbeReqView).uint32
  StaKeyReqPayloadSize = sizeof(StaKeyReqPayload).uint32
  ScanuRawSendCfmPayloadSize = sizeof(ScanuRawSendCfmPayload).uint32
  ScanuRawSendReqPayloadSize = sizeof(ScanuRawSendReqPayload).uint32
  SmConnectAuthAssocReqPayloadSize =
    sizeof(SmConnectAuthAssocReqPayload).uint32
  SmVifIdxReqPayloadSize = sizeof(SmVifIdxReqPayload).uint32
  MmMonitorReqPayloadSize = sizeof(MmMonitorReqPayload).uint32
  MmMonitorCfmPayloadSize = sizeof(MmMonitorCfmPayload).uint32
  StatusCfmPayloadSize = sizeof(StatusCfmPayload).uint32
  Status4CfmPayloadSize = sizeof(Status4CfmPayload).uint32
  SmDisconnectIndPayloadSize = sizeof(SmDisconnectIndPayload).uint32
  SmDisconnectProcessIndPayloadSize =
    sizeof(SmDisconnectProcessIndPayload).uint32
  SmDisconnectReasonPayloadSize = sizeof(SmDisconnectReasonPayload).uint32
  SmStaAddIndPayloadSize = sizeof(SmStaAddIndPayload).uint32
  RcRetryChainParamPayloadSize = sizeof(RcRetryChainParamPayload).uint32
  MeTrafficIndCfmPayloadSize = sizeof(MeTrafficIndCfmPayload).uint32
  MmStaDelKeyCfmPayloadSize = sizeof(MmStaDelKeyCfmPayload).uint32
  BamTrafficStatusPayloadSize = sizeof(BamTrafficStatusPayload).uint32
  IpcEmbMsgDescViewSize = sizeof(IpcEmbMsgDescView).uint32
  ScanChannelEntrySize = sizeof(ScanChannelEntry).uint32
  ScanSsidSlotViewSize = sizeof(ScanSsidSlotView).uint32
  ScanStartReqPayloadSize = sizeof(ScanStartReqPayload).uint32
  ScanuStartReqPayloadSize = sizeof(ScanuStartReqPayload).uint32

static:
  doAssert KeMsgHdrSize == 12'u
  doAssert offsetof(KeMsgEnvelope, header) == 0
  doAssert offsetof(KeMsgEnvelope, payload) == int(KeMsgHdrSize)
  doAssert offsetof(NotifierNodeView, callback) == 0
  doAssert offsetof(NotifierNodeView, next) == 4
  doAssert offsetof(NotifierNodeView, priority) == 8
  doAssert sizeof(NotifierNodeView) == 12
  doAssert offsetof(ElementNotifyContextView, state) == 8
  doAssert sizeof(ElementNotifyContextView) == 12
  doAssert sizeof(KeEnvPsFlagsView) == 5
  doAssert offsetof(KeEnvPsFlagsView, flags) == 0
  doAssert offsetof(KeEnvPsFlagsView, apPending) == 1
  doAssert offsetof(KeEnvPsFlagsView, otherPending) == 3
  doAssert offsetof(KeEnvPsFlagsView, staPending) == 4
  doAssert MmVersionCfmPayloadSize == 24'u32
  doAssert MmStartReqPayloadSize == 9'u32
  doAssert offsetof(MmStartReqPayload, band) == 0
  doAssert offsetof(MmStartReqPayload, chanType) == 1
  doAssert offsetof(MmStartReqPayload, prim20Freq) == 2
  doAssert offsetof(MmStartReqPayload, center1Freq) == 4
  doAssert offsetof(MmStartReqPayload, center2Freq) == 6
  doAssert offsetof(MmStartReqPayload, txPower) == 8
  doAssert MmAddIfCfmPayloadSize == 2'u32
  doAssert MmAddIfReqPayloadSize == 8'u32
  doAssert offsetof(MmAddIfReqPayload, ifType) == 0
  doAssert offsetof(MmAddIfReqPayload, macAddr) == 1
  doAssert offsetof(MmAddIfReqPayload, p2p) == 7
  doAssert MmRemoveIfReqPayloadSize == 1'u32
  doAssert MmConnectionLossIndPayloadSize == 4'u32
  doAssert MmPsChangeIndPayloadSize == 2'u32
  doAssert MmSetPsOptionsReqPayloadSize == 6'u32
  doAssert MmSetIdleReqPayloadSize == 1'u32
  doAssert MmSetBssidReqPayloadSize == 7'u32
  doAssert MmSetBeaconIntReqPayloadSize == 4'u32
  doAssert MmSetBasicRatesReqPayloadSize == 8'u32
  doAssert offsetof(MmSetBasicRatesReqPayload, rateBitfield) == 0
  doAssert offsetof(MmSetBasicRatesReqPayload, vifIdx) == 4
  doAssert offsetof(MmSetBasicRatesReqPayload, band) == 5
  doAssert MmSetEdcaReqPayloadSize == 8'u32
  doAssert offsetof(MmSetEdcaReqPayload, edcaParam) == 0
  doAssert offsetof(MmSetEdcaReqPayload, uapsdAc) == 4
  doAssert offsetof(MmSetEdcaReqPayload, acmFlag) == 5
  doAssert offsetof(MmSetEdcaReqPayload, vifIdx) == 6
  doAssert MmSetVifStateReqPayloadSize == 4'u32
  doAssert MmSetChannelReqPayloadSize == 10'u32
  doAssert offsetof(MmSetChannelReqPayload, band) == 0
  doAssert offsetof(MmSetChannelReqPayload, chanType) == 1
  doAssert offsetof(MmSetChannelReqPayload, prim20Freq) == 2
  doAssert offsetof(MmSetChannelReqPayload, center1Freq) == 4
  doAssert offsetof(MmSetChannelReqPayload, center2Freq) == 6
  doAssert offsetof(MmSetChannelReqPayload, index) == 8
  doAssert offsetof(MmSetChannelReqPayload, txPower) == 9
  doAssert MmSetChannelCfmPayloadSize == 2'u32
  doAssert sizeof(MeAddBaReqParamView) == 18
  doAssert offsetof(MeAddBaReqParamView, ssn) == 8
  doAssert offsetof(MeAddBaReqParamView, timeout) == 10
  doAssert offsetof(MeAddBaReqParamView, amsduSupported) == 14
  doAssert offsetof(MeAddBaReqParamView, bufferSize) == 15
  doAssert offsetof(MeAddBaReqParamView, tid) == 16
  doAssert offsetof(MeAddBaReqParamView, dialogToken) == 17
  doAssert sizeof(AddBaReqActionBodyView) == 9
  doAssert offsetof(AddBaReqActionBodyView, baParams) == 3
  doAssert offsetof(AddBaReqActionBodyView, timeout) == 5
  doAssert offsetof(AddBaReqActionBodyView, startSeq) == 7
  doAssert sizeof(AddBaRspActionBodyView) == 9
  doAssert offsetof(AddBaRspActionBodyView, statusCode) == 3
  doAssert offsetof(AddBaRspActionBodyView, baParams) == 5
  doAssert offsetof(AddBaRspActionBodyView, timeout) == 7
  doAssert sizeof(DelBaActionBodyView) == 6
  doAssert offsetof(DelBaActionBodyView, delbaParams) == 2
  doAssert offsetof(DelBaActionBodyView, reasonCode) == 4
  doAssert offsetof(DelBaInfoView, initiator) == 13
  doAssert offsetof(DelBaInfoView, tid) == 16
  doAssert sizeof(SmAuthFrameView) == 41
  doAssert offsetof(SmAuthFrameView, frameLen) == 0
  doAssert offsetof(SmAuthFrameView, authAlgo) == 32
  doAssert offsetof(SmAuthFrameView, authSeq) == 34
  doAssert offsetof(SmAuthFrameView, statusCode) == 36
  doAssert offsetof(SmAuthFrameView, saeBodyFirst) == 38
  doAssert offsetof(SmAuthFrameView, sharedChallengeFirst) == 40
  doAssert sizeof(SmAssocRspFrameView) == 39
  doAssert offsetof(SmAssocRspFrameView, frameLen) == 0
  doAssert offsetof(SmAssocRspFrameView, capabilityInfo) == 32
  doAssert offsetof(SmAssocRspFrameView, statusCode) == 34
  doAssert offsetof(SmAssocRspFrameView, aid) == 36
  doAssert offsetof(SmAssocRspFrameView, iesFirst) == 38
  doAssert sizeof(AuthFixedBodyView) == 6
  doAssert offsetof(AuthFixedBodyView, authSeq) == 2
  doAssert offsetof(AuthFixedBodyView, statusCode) == 4
  doAssert sizeof(AuthBodyTraceView) == 8
  doAssert offsetof(AuthBodyTraceView, challengeTag) == 6
  doAssert offsetof(AuthBodyTraceView, challengeLen) == 7
  doAssert sizeof(AuthChallengeBodyView) == 136
  doAssert offsetof(AuthChallengeBodyView, challengeTag) == 6
  doAssert offsetof(AuthChallengeBodyView, challengeLen) == 7
  doAssert offsetof(AuthChallengeBodyView, challengeText) == 8
  doAssert offsetof(AuthBodyDataView, data) == sizeof(AuthFixedBodyView)
  doAssert sizeof(ManagementReasonBodyView) == 2
  doAssert offsetof(ManagementReasonBodyView, reason) == 0
  doAssert sizeof(AssocReqFixedBodyView) == 10
  doAssert offsetof(AssocReqFixedBodyView, listenInterval) == 2
  doAssert offsetof(AssocReqFixedBodyView, reassocBssid) == 4
  doAssert sizeof(AssocRspFixedBodyView) == 6
  doAssert offsetof(AssocRspFixedBodyView, statusCode) == 2
  doAssert offsetof(AssocRspFixedBodyView, aid) == 4
  doAssert sizeof(SmDeauthFrameView) == 58
  doAssert offsetof(SmDeauthFrameView, saQueryVifIdx) == 7
  doAssert offsetof(SmDeauthFrameView, vifIdx) == 8
  doAssert offsetof(SmDeauthFrameView, frameFlags) == 27
  doAssert offsetof(SmDeauthFrameView, sa) == 36
  doAssert offsetof(SmDeauthFrameView, bssid) == 48
  doAssert offsetof(SmDeauthFrameView, reason) == 56
  doAssert sizeof(MfpMgmtFramePolicyView) == 37
  doAssert offsetof(MfpMgmtFramePolicyView, frameCtrl) == 0
  doAssert offsetof(MfpMgmtFramePolicyView, bodyOffset) == 8
  doAssert offsetof(MfpMgmtFramePolicyView, staIdx) == 9
  doAssert offsetof(MfpMgmtFramePolicyView, vifIdx) == 10
  doAssert offsetof(MfpMgmtFramePolicyView, flags) == 36
  doAssert sizeof(RxuMgtDispatchView) == 37
  doAssert offsetof(RxuMgtDispatchView, frameCtrl) == 2
  doAssert offsetof(RxuMgtDispatchView, staIdx) == 7
  doAssert offsetof(RxuMgtDispatchView, traceByte8) == 8
  doAssert offsetof(RxuMgtDispatchView, category) == 32
  doAssert offsetof(RxuMgtDispatchView, actionCode) == 33
  doAssert offsetof(RxuMgtDispatchView, dialogToken) == 34
  doAssert offsetof(RxuMgtDispatchView, baParam) == 35
  doAssert sizeof(SmSaQueryFrameView) == 36
  doAssert offsetof(SmSaQueryFrameView, staIdx) == 7
  doAssert offsetof(SmSaQueryFrameView, vifIdx) == 8
  doAssert offsetof(SmSaQueryFrameView, action) == 33
  doAssert offsetof(SmSaQueryFrameView, transId) == 34
  doAssert MmStaAddCfmPayloadSize == 3'u32
  doAssert MmStaAddReqPayloadSize == 28'u32
  doAssert offsetof(MmStaAddReqPayload, vifIdx) == 13
  doAssert offsetof(MmStaAddReqPayload, quickConn) == 25
  doAssert MmStaDelReqPayloadSize == 1'u32
  doAssert MmSetPsModeReqPayloadSize == 1'u32
  doAssert MmRssiStatusIndPayloadSize == 3'u32
  doAssert MmPrimaryTbttIndPayloadSize == 3'u32
  doAssert MmRemainOnChannelReqPayloadSize == 1'u32
  doAssert MmRemainOnChannelCfmPayloadSize == 3'u32
  doAssert MmTimUpdatePayloadSize == 4'u32
  doAssert MmChanCtxtUpdatePayloadSize == 12'u32
  doAssert ChanConnLessDelayReqPayloadSize == 20'u32
  doAssert MeSetPsDisableReqPayloadSize == 2'u32
  doAssert MeSetActiveReqPayloadSize == 2'u32
  doAssert MeStaDelReqPayloadSize == 1'u32
  doAssert MeStaAddCfmPayloadSize == 8'u32
  doAssert MeConfigReqPayloadSize == 49'u32
  doAssert offsetof(MeConfigReqPayload, htCaps) == 0
  doAssert offsetof(MeConfigReqPayload, defKey) == 44
  doAssert offsetof(MeConfigReqPayload, htSupp) == 46
  doAssert offsetof(MeConfigReqPayload, psOn) == 48
  doAssert MeStaAddReqPayloadSize == 74'u32
  doAssert offsetof(MeStaAddReqPayload, macAddr) == 0
  doAssert offsetof(MeStaAddReqPayload, supportedRates) == 6
  doAssert offsetof(MeStaAddReqPayload, capBlockHead) == 20
  doAssert offsetof(MeStaAddReqPayload, htCapInfo) == 22
  doAssert offsetof(MeStaAddReqPayload, capFlags) == 64
  doAssert offsetof(MeStaAddReqPayload, beaconInterval) == 68
  doAssert offsetof(MeStaAddReqPayload, uapsd0) == 70
  doAssert offsetof(MeStaAddReqPayload, uapsd1) == 71
  doAssert offsetof(MeStaAddReqPayload, staIdx) == 73
  doAssert MeRcSetRateReqPayloadSize == 6'u32
  doAssert offsetof(MeRcSetRateReqPayload, staIdx) == 0
  doAssert offsetof(MeRcSetRateReqPayload, fixedRate) == 2
  doAssert offsetof(MeRcSetRateReqPayload, mcsRate) == 4
  doAssert MeTrafficIndReqPayloadSize == 3'u32
  doAssert ApmStartCfmPayloadSize == 4'u32
  doAssert ApmStopReqPayloadSize == 1'u32
  doAssert sizeof(ApmStaDelReqPayload) == 2
  doAssert ApmStaDelCfmPayloadSize == 4'u32
  doAssert sizeof(ApmStaAddCfmParamView) == 1
  doAssert ApmStaDelIndPayloadSize == 6'u32
  doAssert ApmStaAddIndPayloadSize == 28'u32
  doAssert ApmConfMaxStaReqPayloadSize == 1'u32
  doAssert ApmProbeReqViewSize == 48'u32
  doAssert offsetof(ApmProbeReqView, bodyLen) == 0
  doAssert offsetof(ApmProbeReqView, vifIdx) == 8
  doAssert offsetof(ApmProbeReqView, staMac) == 42
  doAssert StaKeyReqPayloadSize == 56'u32
  doAssert offsetof(StaKeyReqPayload, cipherSuite) == 0
  doAssert offsetof(StaKeyReqPayload, keyDataPrefix) == 24
  doAssert offsetof(StaKeyReqPayload, keyType) == 52
  doAssert offsetof(StaKeyReqPayload, keyFlags) == 55
  doAssert sizeof(MachwKeyWriteParamView) == 56
  doAssert offsetof(MachwKeyWriteParamView, addrIdx) == 0
  doAssert offsetof(MachwKeyWriteParamView, keyType) == 1
  doAssert offsetof(MachwKeyWriteParamView, keyLen) == 4
  doAssert offsetof(MachwKeyWriteParamView, keyWords) == 8
  doAssert offsetof(MachwKeyWriteParamView, macLen) == 40
  doAssert offsetof(MachwKeyWriteParamView, macAddr) == 44
  doAssert offsetof(MachwKeyWriteParamView, cipherType) == 52
  doAssert offsetof(MachwKeyWriteParamView, keyIdx) == 53
  doAssert offsetof(MachwKeyWriteParamView, spp) == 54
  doAssert offsetof(MachwKeyWriteParamView, keyFlags) == 55
  doAssert sizeof(IgtkKeyWriteStackView) == 96
  doAssert offsetof(IgtkKeyWriteStackView, resultByte) == 39
  doAssert offsetof(IgtkKeyWriteStackView, req) == 40
  doAssert sizeof(SupplicantKeyParamView) == 56
  doAssert offsetof(SupplicantKeyParamView, addrIdx) == 0
  doAssert offsetof(SupplicantKeyParamView, keyType) == 1
  doAssert offsetof(SupplicantKeyParamView, keyLen) == 4
  doAssert offsetof(SupplicantKeyParamView, keyData) == 8
  doAssert offsetof(SupplicantKeyParamView, macLen) == 40
  doAssert offsetof(SupplicantKeyParamView, macAddr) == 44
  doAssert offsetof(SupplicantKeyParamView, translatedCipher) == 52
  doAssert offsetof(SupplicantKeyParamView, keyIdx) == 53
  doAssert offsetof(SupplicantKeyParamView, spp) == 54
  doAssert offsetof(SupplicantKeyParamView, rawCipher) == 55
  doAssert sizeof(SupplicantTkipKeyDataView) == 32
  doAssert offsetof(SupplicantTkipKeyDataView, temporalKey) == 0
  doAssert offsetof(SupplicantTkipKeyDataView, micTx) == 16
  doAssert offsetof(SupplicantTkipKeyDataView, micRx) == 24
  doAssert offsetof(VifMgmtAddKeyParamView, staIdx) == 0
  doAssert offsetof(VifMgmtAddKeyParamView, ccmpKeyMaterial) == 8
  doAssert offsetof(VifMgmtAddKeyParamView, tkipKeyMaterial) == 24
  doAssert offsetof(VifMgmtAddKeyParamView, pnLowBytes) == 44
  doAssert offsetof(VifMgmtAddKeyParamView, pnHighBytes) == 48
  doAssert offsetof(VifMgmtAddKeyParamView, cipherType) == 52
  doAssert offsetof(VifMgmtAddKeyParamView, keySlot) == 53
  doAssert offsetof(VifMgmtAddKeyParamView, spp) == 54
  doAssert offsetof(VifMgmtAddKeyParamView, hasRxPn) == 55
  doAssert ScanuRawSendCfmPayloadSize == 4'u32
  doAssert ScanuRawSendReqPayloadSize == 8'u32
  doAssert SmConnectAuthAssocReqPayloadSize == 8'u32
  doAssert sizeof(SmConnectIndPayload) == 836
  doAssert offsetof(SmConnectIndPayload, statusCode) == 0
  doAssert offsetof(SmConnectIndPayload, bssid) == 4
  doAssert offsetof(SmConnectIndPayload, securityStatus) == 10
  doAssert offsetof(SmConnectIndPayload, vifIdx) == 11
  doAssert offsetof(SmConnectIndPayload, aid) == 12
  doAssert offsetof(SmConnectIndPayload, channelStatus) == 13
  doAssert offsetof(SmConnectIndPayload, hasWmm) == 14
  doAssert offsetof(SmConnectIndPayload, qosFlag) == 15
  doAssert offsetof(SmConnectIndPayload, assocReqIeLen) == 16
  doAssert offsetof(SmConnectIndPayload, assocRspIeLen) == 18
  doAssert offsetof(SmConnectIndPayload, assocIeBuffer) == 20
  doAssert offsetof(SmConnectIndPayload, chanBand) == 822
  doAssert offsetof(SmConnectIndPayload, chanPrimFreq) == 824
  doAssert offsetof(SmConnectIndPayload, chanType) == 826
  doAssert offsetof(SmConnectIndPayload, chanCenterFreq1) == 828
  doAssert offsetof(SmConnectIndPayload, chanCenterFreq2) == 832
  doAssert SmVifIdxReqPayloadSize == 1'u32
  doAssert MmMonitorReqPayloadSize == 4'u32
  doAssert MmMonitorCfmPayloadSize == 40'u32
  doAssert StatusCfmPayloadSize == 1'u32
  doAssert Status4CfmPayloadSize == 4'u32
  doAssert SmDisconnectIndPayloadSize == 12'u32
  doAssert SmDisconnectProcessIndPayloadSize == 16'u32
  doAssert SmDisconnectReasonPayloadSize == 2'u32
  doAssert SmStaAddIndPayloadSize == 3'u32
  doAssert RcRetryChainParamPayloadSize == 4'u32
  doAssert MeTrafficIndCfmPayloadSize == 4'u32
  doAssert MmStaDelKeyCfmPayloadSize == 2'u32
  doAssert BamTrafficStatusPayloadSize == 56'u32
  doAssert IpcEmbMsgDescViewSize == 8'u32
  doAssert offsetof(IpcEmbMsgEnvelopeView, desc) == 0
  doAssert offsetof(IpcEmbMsgEnvelopeView, payload) == 8
  doAssert offsetof(IpcSharedMsgView, id) == 4
  doAssert offsetof(IpcSharedMsgView, dstId) == 6
  doAssert offsetof(IpcSharedMsgView, srcId) == 7
  doAssert offsetof(IpcSharedMsgView, paramLen) == 8
  doAssert offsetof(IpcSharedMsgView, payload) == 12
  doAssert sizeof(IpcSharedEnvView) == 0x24DC
  doAssert offsetof(IpcSharedEnvView, id) == 4
  doAssert offsetof(IpcSharedEnvView, payloadArea) == 12
  doAssert offsetof(IpcSharedEnvView, hostTxListCursor) == 0x24CC
  doAssert offsetof(IpcSharedEnvView, hostTxCfmCursor) == 0x24D4
  doAssert sizeof(IpcEmbEnvView) == 20
  doAssert offsetof(IpcEmbEnvView, counter) == 0
  doAssert offsetof(IpcEmbEnvView, hostTxList) == 12
  doAssert offsetof(IpcEmbEnvView, hostTxCfmList) == 16
  doAssert offsetof(IpcHostTxWrapperView, active) == 8
  doAssert offsetof(IpcHostTxWrapperView, txDesc) == 12
  doAssert sizeof(IpcTxAcDescView) == 16
  doAssert IPC_TX_AC_DESC_STRIDE == sizeof(IpcTxAcDescView).uint32
  doAssert offsetof(IpcTxAcDescView, descriptor) == 0
  doAssert offsetof(IpcTxAcDescView, descPtr) == 4
  doAssert offsetof(IpcTxAcDescView, sequence) == 12
  doAssert offsetof(IpcTxAcDescView, busy) == 14
  doAssert sizeof(IpcTxHwDescWordTableView) == NUM_TX_QUEUES * sizeof(uint32)
  doAssert offsetof(IpcTxHwDescWordTableView, descriptorWords) == 0
  doAssert ScanChannelEntrySize == 6'u32
  doAssert ScanSsidSlotViewSize == 34'u32
  doAssert offsetof(ScanSsidSlotView, length) == 0
  doAssert offsetof(ScanSsidSlotView, data) == 1
  doAssert ScanStartReqPayloadSize == 316'u32
  doAssert offsetof(ScanStartReqPayload, bssid) == 286
  doAssert offsetof(ScanStartReqPayload, localMac) == 292
  doAssert offsetof(ScanStartReqPayload, ieBodyLen) == 304
  doAssert ScanuStartReqPayloadSize == 320'u32
  doAssert offsetof(ScanuStartReqPayload, bssid) == 286
  doAssert offsetof(ScanuStartReqPayload, localMac) == 292
  doAssert offsetof(ScanuStartReqPayload, probeReqIe) == 300
  doAssert sizeof(TxControlAcView) == 16
  doAssert offsetof(TxControlAcView, current) == 0
  doAssert offsetof(TxControlAcView, pending) == 4
  doAssert offsetof(TxControlAcView, packetCount) == 12
  doAssert sizeof(TxControlEnvView) == 92
  doAssert offsetof(TxControlEnvView, ac) == 0
  doAssert offsetof(TxControlEnvView, packetCounter) == 80
  doAssert offsetof(TxControlEnvView, seqCounter) == 84
  doAssert offsetof(TxControlEnvView, resetInProgress) == 88
  doAssert sizeof(TxCfmEnvView) == 40
  doAssert offsetof(TxCfmEnvView, lists) == 0
  doAssert offsetof(MachwTxQueueRegsView, txStatus) == 0x78
  doAssert offsetof(MachwTxQueueRegsView, readyAck) == 0x7C
  doAssert offsetof(MachwTxQueueRegsView, txAggSet) == 0x88
  doAssert offsetof(MachwTxQueueRegsView, txAggActive) == 0x8C
  doAssert offsetof(MachwTxQueueRegsView, txTrigger) == 0x180
  doAssert offsetof(MachwTxQueueRegsView, dmaStatus) == 0x188
  doAssert offsetof(MachwTxQueueRegsView, beaconHead) == 0x198
  doAssert offsetof(MachwTxQueueRegsView, ac0Head) == 0x19C
  doAssert offsetof(MachwTxQueueRegsView, ac3Head) == 0x1A8
  doAssert offsetof(MachwRxDmaRegsView, trigger) == 0x180
  doAssert offsetof(MachwRxDmaRegsView, hdSubmittedHead) == 0x1B8
  doAssert offsetof(MachwRxDmaRegsView, pdSubmittedHead) == 0x1BC
  doAssert offsetof(MachwRxDmaRegsView, hdHwHead) == 0x548
  doAssert offsetof(MachwRxDmaRegsView, pdHwHead) == 0x54C
  doAssert offsetof(MachwSecurityRegsView, keyMaterial) == 0x0AC
  doAssert offsetof(MachwSecurityRegsView, dataLow) == 0x0BC
  doAssert offsetof(MachwSecurityRegsView, dataHigh) == 0x0C0
  doAssert offsetof(MachwSecurityRegsView, control) == 0x0C4
  doAssert offsetof(MachwSecurityRegsView, keyCount) == 0x0D8
  doAssert offsetof(WlanCoexRegsView, control) == 0x00
  doAssert offsetof(WlanCoexRegsView, pti) == 0x04
  doAssert offsetof(WlanCoexRegsView, status) == 0x08
  doAssert offsetof(PtaCoexRegsView, control) == 0x004
  doAssert offsetof(PtaCoexRegsView, control2) == 0x028
  doAssert offsetof(PtaCoexRegsView, mirror) == 0x404
  doAssert offsetof(PtaCoexRegsView, clear) == 0x428
  doAssert sizeof(RcRateEntryView) == RC_RATE_ENTRY_SIZE
  doAssert offsetof(RcRateEntryView, attempts) == 4
  doAssert offsetof(RcRateEntryView, failures) == 6
  doAssert offsetof(RcRateEntryView, probEwma) == 8
  doAssert offsetof(RcRateEntryView, rateConfig) == 10
  doAssert offsetof(RcRateResetFieldsView, attempts0) == 0
  doAssert offsetof(RcRateResetFieldsView, oldProb) == 5
  doAssert offsetof(RcRateResetFieldsView, sampleSkipped) == 6
  doAssert offsetof(RcRateResetFieldsView, initialized) == 7
  doAssert sizeof(RcRetrySlotView) == 8
  doAssert offsetof(RcStatsCounterView, retrySlots) == 128
  doAssert offsetof(RcStatsCounterView, sampleCandidate) == RCS_SAMPLE_CAND
  doAssert offsetof(RcStatsCounterView, totalAttempts) == RCS_TOTAL_ATTEMPTS
  doAssert offsetof(RcStatsCounterView, totalSuccess) == RCS_TOTAL_SUCCESS
  doAssert offsetof(RcStatsCounterView, avgAmpduLen) == RCS_AVG_AMPDU_LEN
  doAssert offsetof(RcStatsCounterView, retryLimit) == RCS_RETRY_LIMIT
  doAssert offsetof(RcStatsCounterView, updateStage) == RCS_UPDATE_STAGE
  doAssert offsetof(RcStatsCounterView, flags) == RCS_FLAGS
  doAssert offsetof(RcStatsCounterView, nssMax) == 187
  doAssert offsetof(RcStatsCounterView, bwMax) == 188
  doAssert offsetof(RcStatsCounterView, legacyRateMap) == RCS_RATE_MAP_L
  doAssert offsetof(RcStatsCounterView, fixedRate) == 198
  doAssert sizeof(RcStatsCounterView) == RC_STATS_SIZE
  doAssert sizeof(TxFrameEnvView) == 20
  doAssert offsetof(TxFrameEnvView, freeList) == 0
  doAssert offsetof(TxFrameEnvView, usedList) == 8
  doAssert offsetof(TxFrameEnvView, postponedCount) == 16
  doAssert sizeof(MeEnvView) == 136
  doAssert offsetof(MeEnvView, activeMask) == 0
  doAssert offsetof(MeEnvView, psDisableMask) == 4
  doAssert offsetof(MeEnvView, htCaps) == 8
  doAssert offsetof(MeEnvView, chanConfig) == 40
  doAssert offsetof(MeEnvView, psMode) == 126
  doAssert offsetof(MeEnvView, defKey) == 128
  doAssert offsetof(MeEnvView, htSupp) == 130
  doAssert offsetof(MeEnvView, nss) == 131
  doAssert offsetof(MeEnvView, htCapByte) == 132
  doAssert offsetof(MeEnvView, psOn) == 133
  doAssert sizeof(MeChannelConfigEntry) == 6
  doAssert sizeof(MeChannelConfigView) == 86
  doAssert offsetof(MeChannelConfigView, entries) == 0
  doAssert offsetof(MeChannelConfigView, count) == 84
  doAssert offsetof(MeBeaconSequenceOverlay, seqCounter) == 84
  doAssert sizeof(MmEnvView) == 68
  doAssert offsetof(MmEnvView, rxFilterBase) == 0
  doAssert offsetof(MmEnvView, rxFilterExtra) == 4
  doAssert offsetof(MmEnvView, edcaBkDur) == 8
  doAssert offsetof(MmEnvView, edcaBcnDur) == 16
  doAssert offsetof(MmEnvView, previousState) == 18
  doAssert offsetof(MmEnvView, hardwareMode) == 19
  doAssert offsetof(MmEnvView, listenWindow) == 24
  doAssert offsetof(MmEnvView, idleFlag) == 26
  doAssert offsetof(MmEnvView, flagsHigh) == 27
  doAssert offsetof(MmEnvView, keepAliveInterval) == 28
  doAssert offsetof(MmEnvView, keepAliveLimit) == 32
  doAssert offsetof(MmEnvView, keepAliveCounter) == 36
  doAssert offsetof(MmEnvView, keepAliveTimestamp) == 40
  doAssert offsetof(MmEnvView, rxPromiscUploadFlag) == 44
  doAssert offsetof(MmEnvView, apPromiscUploadFlag) == 48
  doAssert offsetof(MmEnvView, maxAmpduDuration) == 52
  doAssert offsetof(MmWmmParameterSourceView, acBk) == 8
  doAssert offsetof(MmWmmParameterSourceView, acBe) == 12
  doAssert offsetof(MmWmmParameterSourceView, acVi) == 16
  doAssert offsetof(MmWmmParameterSourceView, acVo) == 20
  doAssert offsetof(MmWmmParameterSourceView, idlePeriod) == 24
  doAssert offsetof(MmWmmParameterSourceView, idleOptions) == 26
  doAssert sizeof(MmBcnEnvView) == 20
  doAssert offsetof(MmBcnEnvView, templatePtr) == 0
  doAssert offsetof(MmBcnEnvView, pendingCount) == 4
  doAssert offsetof(MmBcnEnvView, transmitRequested) == 8
  doAssert offsetof(MmBcnEnvView, active) == 9
  doAssert offsetof(MmBcnEnvView, deferredChange) == 10
  doAssert offsetof(MmBcnEnvView, timQueue) == 12
  doAssert offsetof(BeaconChangeReqView, frameLen) == 4
  doAssert offsetof(BeaconChangeReqView, headerLen) == 6
  doAssert offsetof(BeaconChangeReqView, flagByte) == 8
  doAssert offsetof(BeaconChangeReqView, vifIdx) == 9
  doAssert offsetof(BeaconChangeReqView, frameData) == 12
  doAssert sizeof(BeaconEndDescView) == 20
  doAssert offsetof(BeaconEndDescView, payloadStart) == 8
  doAssert offsetof(BeaconEndDescView, payloadEnd) == 12
  doAssert offsetof(BeaconEndDescView, status) == 16
  doAssert sizeof(TimDescView) == 36
  doAssert offsetof(TimDescView, next) == 4
  doAssert offsetof(TimDescView, payloadStart) == 8
  doAssert offsetof(TimDescView, payloadEnd) == 12
  doAssert offsetof(TimDescView, status) == 16
  doAssert offsetof(TimDescView, bitmapMagic) == 20
  doAssert offsetof(TimDescView, bitmapNext) == 24
  doAssert offsetof(TimDescView, bitmapStart) == 28
  doAssert offsetof(TimDescView, bitmapEnd) == 32
  doAssert sizeof(VifMgmtEnvView) == 20
  doAssert offsetof(VifMgmtEnvView, freeList) == 0
  doAssert offsetof(VifMgmtEnvView, activeList) == 8
  doAssert offsetof(VifMgmtEnvView, staCount) == 16
  doAssert offsetof(VifMgmtEnvView, apCount) == 17
  doAssert offsetof(VifMgmtEnvView, primaryApIdx) == 18
  doAssert offsetof(VifMgmtHostapdOpsEnvView, hostapdOps) == 12
  doAssert offsetof(VifHostapdPrivView, hostapdPriv) == 364
  doAssert offsetof(VifApProbeSsidOverlay, hiddenSsidMode) == 385
  doAssert offsetof(VifApProbeSsidOverlay, ssidLen) == 386
  doAssert offsetof(VifApProbeSsidOverlay, ssidData) == 387

  doAssert sizeof(PsEnvView) == 56
  doAssert offsetof(PsEnvView, enabled) == 0
  doAssert offsetof(PsEnvView, mode) == 1
  doAssert offsetof(PsEnvView, statusFlags) == 4
  doAssert offsetof(PsEnvView, pendingCount) == 8
  doAssert offsetof(PsEnvView, nullRetryLimit) == 12
  doAssert offsetof(PsEnvView, uapsdTimerCallback) == 16
  doAssert offsetof(PsEnvView, uapsdTimerActive) == 28
  doAssert offsetof(PsEnvView, psActive) == 29
  doAssert offsetof(PsEnvView, uapsdPeriod) == 32
  doAssert offsetof(PsEnvView, txNullTimerWord) == 36
  doAssert offsetof(PsEnvView, txNullTimerCallback) == 40
  doAssert offsetof(PsEnvView, currentVif) == 44
  doAssert offsetof(PsEnvView, uapsdTimerState) == 48
  doAssert offsetof(PsEnvView, flags) == 52
  doAssert offsetof(PsEnvView, deferredMode) == 53
  doAssert offsetof(PsDozeEnvView, dozeInProgress) == 56
  doAssert offsetof(PsDozeEnvView, preState) == 60
  doAssert sizeof(SmEnvView) == 56
  doAssert offsetof(SmEnvView, connectInfo) == 0
  doAssert offsetof(SmEnvView, connectIndMsg) == 4
  doAssert offsetof(SmEnvView, pendingBssParams) == 8
  doAssert offsetof(SmEnvView, joinBssFlag) == 16
  doAssert offsetof(SmEnvView, deauthPending) == 17
  doAssert offsetof(SmEnvView, cancelRequested) == 18
  doAssert offsetof(SmEnvView, connectFlags) == 19
  doAssert offsetof(SmEnvView, connectModeFlags) == 20
  doAssert offsetof(SmEnvView, authRetryLimit) == 24
  doAssert offsetof(SmEnvView, scanResultIndex) == 28
  doAssert offsetof(SmEnvView, primaryFreq) == 32
  doAssert offsetof(SmEnvView, centerFreq) == 34
  doAssert offsetof(SmEnvView, saQueryActive) == 36
  doAssert offsetof(SmEnvView, saQueryRetryCount) == 37
  doAssert offsetof(SmEnvView, saQueryVifIdx) == 38
  doAssert offsetof(SmEnvView, saQueryField39) == 39
  doAssert offsetof(SmEnvView, saQueryTransId) == 40
  doAssert offsetof(SmEnvView, saQueryReason) == 42
  doAssert offsetof(SmEnvView, state) == 44
  doAssert offsetof(SmEnvView, vendorIePtr) == 48
  doAssert offsetof(SmEnvView, vendorIeLen) == 52
  doAssert sizeof(ApmEnvView) == 176
  doAssert offsetof(ApmEnvView, connectInfo) == 0
  doAssert offsetof(ApmEnvView, pendingBssParams) == 4
  doAssert offsetof(ApmEnvView, pendingBeaconBuffer) == 16
  doAssert offsetof(ApmEnvView, securityIe) == 20
  doAssert offsetof(ApmEnvView, cryptoType) == 84
  doAssert offsetof(ApmEnvView, beaconIntervalIndex) == 85
  doAssert offsetof(ApmEnvView, flags) == 86
  doAssert offsetof(ApmEnvView, staCount) == 87
  doAssert offsetof(ApmEnvView, maxSta) == 88
  doAssert offsetof(ApmEnvView, vifIdx) == 89
  doAssert offsetof(ApmEnvView, selfStaIdx) == 90
  doAssert offsetof(ApmEnvView, hostapdCtx) == 172
  doAssert offsetof(ApmStaSlotOverlay, macAddr) == 12
  doAssert offsetof(ApmStaSlotOverlay, staHandle) == 20
  doAssert offsetof(ApmStaSlotOverlay, active) == 24
  doAssert offsetof(ApmStaSlotOverlay, staIdx) == 25
  doAssert sizeof(ConnectInfoView) == 62
  doAssert offsetof(ConnectInfoView, ssidLen) == 0
  doAssert offsetof(ConnectInfoView, ssid) == 1
  doAssert offsetof(ConnectInfoView, bssid) == 34
  doAssert offsetof(ConnectInfoView, channelHint) == 40
  doAssert offsetof(ConnectInfoView, channelDuration) == 48
  doAssert offsetof(ConnectInfoView, ctrlPortEthertype) == 52
  doAssert offsetof(ConnectInfoView, listenInterval) == 54
  doAssert offsetof(ConnectInfoView, psOptions) == 56
  doAssert offsetof(ConnectInfoView, authType) == 57
  doAssert offsetof(ConnectInfoView, qosInfo) == 58
  doAssert offsetof(ConnectInfoView, vifIdx) == 59
  doAssert offsetof(ConnectInfoView, authRetry) == 60
  doAssert offsetof(ConnectInfoView, authRetryGate) == 61
  doAssert offsetof(ConnectInfoCredentialOverlay, keyString) == 62
  doAssert offsetof(ConnectInfoCredentialOverlay, altSsid) == 126
  doAssert offsetof(ConnectInfoChannelContextOverlay, chanType) == 479
  doAssert sizeof(ApmStartInfoView) == 250
  doAssert offsetof(ApmStartInfoView, staRateSeed) == 0
  doAssert offsetof(ApmStartInfoView, beaconTemplate) == 32
  doAssert offsetof(ApmStartInfoView, beaconLength) == 36
  doAssert offsetof(ApmStartInfoView, timOffset) == 38
  doAssert offsetof(ApmStartInfoView, beaconInterval) == 40
  doAssert offsetof(ApmStartInfoView, beaconRateInfo) == 44
  doAssert offsetof(ApmStartInfoView, vifBeaconInterval) == 48
  doAssert offsetof(ApmStartInfoView, csaOffset0) == 50
  doAssert offsetof(ApmStartInfoView, vifIdx) == 51
  doAssert offsetof(ApmStartInfoView, basicRateCount) == 248
  doAssert offsetof(ApmStartInfoView, basicRates) == 249
  doAssert sizeof(ApmStartChannelView) == 15
  doAssert offsetof(ApmStartChannelView, freq) == 0
  doAssert offsetof(ApmStartChannelView, band) == 2
  doAssert offsetof(ApmStartChannelView, chanType) == 4
  doAssert offsetof(ApmStartChannelView, primFreq) == 6
  doAssert offsetof(ApmStartChannelView, centerFreq) == 10
  doAssert offsetof(ApmStartChannelView, authType) == 14
  doAssert sizeof(ApmStartReqView) == 170
  doAssert offsetof(ApmStartReqView, channel) == 14
  doAssert offsetof(ApmStartReqView, flags) == 29
  doAssert offsetof(ApmStartReqView, beaconLength) == 36
  doAssert offsetof(ApmStartReqView, beaconLenOut) == 38
  doAssert offsetof(ApmStartReqView, beaconInterval) == 40
  doAssert offsetof(ApmStartReqView, beaconFlags) == 50
  doAssert offsetof(ApmStartReqView, vifIdx) == 51
  doAssert offsetof(ApmStartReqView, beaconIntervalIndex) == 52
  doAssert offsetof(ApmStartReqView, basicRates) == 53
  doAssert offsetof(ApmStartReqView, dtimPeriod) == 66
  doAssert offsetof(ApmStartReqView, supportedRatesLong) == 68
  doAssert offsetof(ApmStartReqView, htCapSsidLen) == 102
  doAssert offsetof(ApmStartReqView, ssid) == 103
  doAssert offsetof(ApmStartReqView, cryptoType) == 168
  doAssert offsetof(ApmStartReqView, securityIe) == 169
  doAssert offsetof(MmBcnChangeReqPayload, beaconTemplate) == 0
  doAssert offsetof(MmBcnChangeReqPayload, beaconLength) == 4
  doAssert offsetof(MmBcnChangeReqPayload, timOffset) == 6
  doAssert offsetof(MmBcnChangeReqPayload, csaOffset0) == 8
  doAssert offsetof(MmBcnChangeReqPayload, csaOffset1) == 9
  doAssert offsetof(MmBcnChangeReqPayload, beaconData) == 12
  doAssert sizeof(ApmRxMgmtPrefixView) == 67
  doAssert offsetof(ApmRxMgmtPrefixView, staIdx) == 7
  doAssert offsetof(ApmRxMgmtPrefixView, vifIdx) == 8
  doAssert offsetof(ApmRxMgmtPrefixView, assocWord16) == 16
  doAssert offsetof(ApmRxMgmtPrefixView, assocWord20) == 20
  doAssert offsetof(ApmRxMgmtPrefixView, assocByte24) == 24
  doAssert offsetof(ApmRxMgmtPrefixView, assocByte28) == 28
  doAssert offsetof(ApmRxMgmtPrefixView, staMac) == 42
  doAssert offsetof(ApmRxMgmtPrefixView, reason) == 56
  doAssert offsetof(ApmRxMgmtPrefixView, bodyLen) == 58
  doAssert offsetof(ApmRxMgmtPrefixView, bodyPrefix) == 60
  doAssert sizeof(ApmAssocStaAddIndPayload) == 88
  doAssert offsetof(ApmAssocStaAddIndPayload, macAddr) == 0
  doAssert offsetof(ApmAssocStaAddIndPayload, rateCount) == 6
  doAssert offsetof(ApmAssocStaAddIndPayload, rateBytes) == 7
  doAssert offsetof(ApmAssocStaAddIndPayload, rateBitfield) == 56
  doAssert offsetof(ApmAssocStaAddIndPayload, translatedRate) == 60
  doAssert offsetof(ApmAssocStaAddIndPayload, flags) == 64
  doAssert offsetof(ApmAssocStaAddIndPayload, aid) == 68
  doAssert offsetof(ApmAssocStaAddIndPayload, status) == 72
  doAssert offsetof(ApmAssocStaAddIndPayload, vifIdx) == 73
  doAssert offsetof(ApmAssocStaAddIndPayload, assocWord16) == 76
  doAssert offsetof(ApmAssocStaAddIndPayload, assocWord20) == 80
  doAssert offsetof(ApmAssocStaAddIndPayload, assocByte24) == 84
  doAssert offsetof(ApmAssocStaAddIndPayload, assocByte28) == 85
  doAssert offsetof(ApmAssocStaAddIndHtOverlay, capInfo) == 20
  doAssert offsetof(ApmAssocStaAddIndHtOverlay, extendedCap) == 40
  doAssert offsetof(ApmAssocStaAddIndHtOverlay, txBfCap) == 44
  doAssert offsetof(ApmAssocStaAddIndHtOverlay, aselCap) == 48
  doAssert sizeof(MmTimerView) == 16
  doAssert sizeof(ChanCtxtDefView) == 10
  doAssert sizeof(ChanCtxtView) == 28
  doAssert sizeof(ChanScanPoolOverlay) == 22
  doAssert offsetof(ChanScanPoolOverlay, channel) == 0
  doAssert offsetof(ChanScanPoolOverlay, vifIdx) == 10
  doAssert offsetof(ChanScanPoolOverlay, durationTicks) == 14
  doAssert offsetof(ChanScanPoolOverlay, active) == 18
  doAssert offsetof(ChanScanPoolOverlay, slot) == 19
  doAssert offsetof(ChanScanPoolOverlay, requestVifIdx) == 21
  doAssert sizeof(ChanRocOverlay) == 22
  doAssert offsetof(ChanRocOverlay, vifIdx) == 0
  doAssert offsetof(ChanRocOverlay, durationTicks) == 4
  doAssert offsetof(ChanRocOverlay, stateLo) == 8
  doAssert offsetof(ChanRocOverlay, slot) == 9
  doAssert offsetof(ChanRocOverlay, band) == 11
  doAssert offsetof(ChanRocOverlay, channel) == 12
  doAssert sizeof(ChanTbttNodeView) == 12
  doAssert offsetof(VifChannelView, tbttTimer) == 24
  doAssert offsetof(VifChannelView, beaconTimeoutTimer) == 40
  doAssert offsetof(VifChannelView, currentBssid) == 56
  doAssert offsetof(VifChannelView, chanCtxt) == 64
  doAssert offsetof(VifChannelView, edcaRegs) == 8
  doAssert offsetof(VifChannelView, tbttNode) == 68
  doAssert offsetof(VifChannelView, macAddr) == 80
  doAssert offsetof(VifChannelView, vifType) == 86
  doAssert offsetof(VifChannelView, vifIdx) == 87
  doAssert offsetof(VifChannelView, state) == 88
  doAssert offsetof(VifChannelView, txPower) == 89
  doAssert offsetof(VifChannelView, maxTxPower) == 90
  doAssert offsetof(VifChannelView, psFlags) == 91
  doAssert offsetof(VifChannelView, listenInterval) == 92
  doAssert offsetof(VifChannelView, psOptions) == 94
  doAssert offsetof(VifChannelView, psNullRetry) == 95
  doAssert offsetof(VifChannelView, staIdx) == 96
  doAssert offsetof(VifChannelView, psLastTime) == 100
  doAssert offsetof(VifChannelView, uapsdBitmap) == 104
  doAssert offsetof(VifChannelView, beaconTimeoutBase) == 108
  doAssert offsetof(VifChannelView, beaconCrc) == 112
  doAssert offsetof(VifChannelView, probeCount) == 116
  doAssert offsetof(VifChannelView, tbttCount) == 120
  doAssert offsetof(VifChannelView, beaconLossCount) == 124
  doAssert offsetof(VifChannelView, beaconRxCount) == 128
  doAssert offsetof(VifChannelView, beaconLossWindow) == 132
  doAssert offsetof(VifChannelView, lastBeaconMacTime) == 136
  doAssert offsetof(VifChannelView, keepAliveTimer) == 140
  doAssert offsetof(VifChannelView, securityTimer) == 172
  doAssert offsetof(VifChannelView, rssiLast) == 188
  doAssert offsetof(VifChannelView, rssiThreshold) == 189
  doAssert offsetof(VifChannelView, rssiHysteresis) == 190
  doAssert offsetof(VifChannelView, rssiState) == 191
  doAssert offsetof(VifChannelView, keyPsState) == 196
  doAssert offsetof(VifChannelView, beaconTxDesc) == 208
  doAssert offsetof(VifChannelView, beaconTxCallback) == 304
  doAssert offsetof(VifChannelView, beaconTxCallbackArg) == 308
  doAssert offsetof(VifChannelView, beaconBodyLength) == 316
  doAssert offsetof(VifChannelView, timLength) == 318
  doAssert offsetof(VifChannelView, timCount) == 320
  doAssert offsetof(VifChannelView, apBeaconInterval) == 322
  doAssert offsetof(VifChannelView, beaconDivisor) == 324
  doAssert offsetof(VifChannelView, beaconCountdown) == 325
  doAssert offsetof(VifChannelView, beaconEnabled) == 326
  doAssert offsetof(VifChannelView, timCountdown) == 327
  doAssert offsetof(VifChannelView, timMin) == 328
  doAssert offsetof(VifChannelView, timMax) == 329
  doAssert offsetof(VifChannelView, timFlags) == 330
  doAssert offsetof(VifChannelView, psBaCounter) == 334
  doAssert offsetof(VifChannelView, apStartBeaconInterval) == 336
  doAssert offsetof(VifChannelView, apChanSwitchPending) == 338
  doAssert offsetof(VifChannelView, postponedStaHead) == 340
  doAssert offsetof(VifChannelView, reserved344) == 344
  doAssert offsetof(VifChannelView, bssid) == 380
  doAssert offsetof(VifChannelView, supportedRatesLong) == 386
  doAssert offsetof(VifChannelView, scanBand) == 420
  doAssert offsetof(VifChannelView, operChan) == 424
  doAssert offsetof(VifChannelView, channelFreqPair) == 428
  doAssert offsetof(VifChannelView, beaconIntervalTu) == 432
  doAssert offsetof(VifChannelView, capabilityInfo) == 434
  doAssert offsetof(VifChannelView, basicRates) == 436
  doAssert offsetof(VifChannelView, wmmQosInfo) == 452
  doAssert offsetof(VifChannelView, wmmAcFlags) == 453
  doAssert offsetof(VifChannelView, edcaParams) == 456
  doAssert offsetof(VifSecurityOverlay, connected) == 0
  doAssert offsetof(VifSecurityOverlay, rsnIePtr) == 4
  doAssert offsetof(VifSecurityOverlay, rsnIeLen) == 8
  doAssert offsetof(VifSecurityOverlay, cipher) == 9
  doAssert offsetof(VifSecurityOverlay, groupCipher) == 10
  doAssert offsetof(VifSecurityOverlay, pairwiseCipher) == 11
  doAssert offsetof(VifSecurityOverlay, keyMgmtByte) == 12
  doAssert offsetof(VifSecurityOverlay, keyMgmt) == 16
  doAssert offsetof(VifSecurityOverlay, pmfCapable) == 20
  doAssert offsetof(VifSecurityOverlay, pmfRequired) == 21
  doAssert offsetof(VifSecurityOverlay, staKeySlots) == 22
  doAssert sizeof(VifSecurityOverlay) == 26
  doAssert offsetof(VifMachwKeyIndexOverlay, primaryPairwise) == 172
  doAssert offsetof(VifMachwKeyIndexOverlay, secondaryPairwise) == 173
  doAssert offsetof(VifMachwKeyIndexOverlay, group) == 174
  doAssert offsetof(VifHtCapabilitiesOverlay, capInfo) == 0
  doAssert offsetof(VifHtCapabilitiesOverlay, ampduParams) == 2
  doAssert offsetof(VifHtCapabilitiesOverlay, mcsSet) == 3
  doAssert offsetof(VifHtCapabilitiesOverlay, extCap) == 20
  doAssert offsetof(VifHtCapabilitiesOverlay, txBfCaps) == 24
  doAssert offsetof(VifHtCapabilitiesOverlay, aselCap) == 28
  doAssert sizeof(VifHtCapabilitiesOverlay) == 29
  doAssert offsetof(VifHtOperationOverlay, flags) == 0
  doAssert offsetof(VifHtOperationOverlay, secChan) == 3
  doAssert offsetof(VifHtOperationOverlay, chanWidth) == 4
  doAssert offsetof(VifApConfigOverlay, noiseFloor1) == 17
  doAssert offsetof(VifApConfigOverlay, noiseFloor2) == 18
  doAssert offsetof(VifApConfigOverlay, highestRateBit) == 19
  doAssert offsetof(VifApConfigOverlay, authType) == 22
  doAssert offsetof(VifApConfigOverlay, requestedAuthType) == 23
  doAssert offsetof(VifApConfigOverlay, securityFlags) == 28
  doAssert offsetof(VifApConfigOverlay, beaconInterval) == 58
  doAssert offsetof(VifApConfigOverlay, aidBitmapFeatureLow) == 60
  doAssert offsetof(VifApConfigOverlay, maxAssocRate) == 62
  doAssert offsetof(VifApConfigOverlay, privacyFlag) == 64
  doAssert offsetof(VifAssocInfoOverlay, ssidLen) == 38
  doAssert offsetof(VifAssocInfoOverlay, ssidData) == 39
  doAssert offsetof(VifAssocInfoOverlay, basicRates) == 88
  doAssert offsetof(VifAssocInfoOverlay, modeByte104) == 104
  doAssert offsetof(VifAssocInfoOverlay, securityFlags) == 136
  doAssert offsetof(VifAssocInfoOverlay, rsnIePtr) == 144
  doAssert offsetof(VifAssocInfoOverlay, rsnIeLen) == 148
  doAssert sizeof(KeyReplayCounterView) == 16
  doAssert sizeof(ReplayCounterWindowSlot) == 12
  doAssert offsetof(ReplayCounterWindowSlot, valid) == 8
  doAssert sizeof(ReplayCounterStateView) == 32
  doAssert offsetof(ReplayCounterStateView, pnLow) == 0
  doAssert offsetof(ReplayCounterStateView, pnHigh) == 4
  doAssert offsetof(ReplayCounterStateView, slots) == 8
  doAssert offsetof(VifKeySlotView, replayCounters) == 0
  doAssert offsetof(VifKeySlotView, pnLow) == 128
  doAssert offsetof(VifKeySlotView, pnHigh) == 132
  doAssert offsetof(VifKeySlotView, keyMaterial) == 136
  doAssert offsetof(VifKeySlotView, cipherType) == 152
  doAssert offsetof(VifKeySlotView, staIdx) == 153
  doAssert offsetof(VifKeySlotView, keyIdx) == 154
  doAssert offsetof(VifKeySlotView, installed) == 155
  doAssert offsetof(VifKeySlotView, hasRxPn) == 156
  doAssert sizeof(VifKeySlotView) == 160
  doAssert sizeof(TkipMicKeyAreaView) == 32
  doAssert offsetof(TkipMicKeyAreaView, scratch) == 4
  doAssert offsetof(TkipMicKeyAreaView, keyMaterial) == 24
  doAssert sizeof(RxMicWordsView) == 8
  doAssert offsetof(RxMicWordsView, hi) == 4
  doAssert offsetof(VifKeyPointersView, defaultKeyPtr) == 0
  doAssert offsetof(VifKeyPointersView, groupKeyPtr) == 4
  doAssert offsetof(VifKeyPointersView, flags) == 8
  doAssert sizeof(VifKeyPointersView) == 12
  doAssert offsetof(VifRxProtectedKeyTableOverlay, slots) == 528
  doAssert offsetof(VifKeySlotTableOverlay, slots) == 528
  doAssert offsetof(TxSecurityKeyListView, pairwiseKey) == 0
  doAssert sizeof(TxSecurityKeyListView) == sizeof(pointer)
  doAssert offsetof(SecMacRxIndView, staIdx) == 0
  doAssert offsetof(SecMacRxIndView, length) == 2
  doAssert offsetof(SecMacRxIndView, payload) == 4
  doAssert sizeof(TxPolicyView) == 60
  doAssert offsetof(TxPolicyView, status) == 0
  doAssert offsetof(TxPolicyView, bufferAddr) == 4
  doAssert offsetof(TxPolicyView, bufferMask) == 8
  doAssert offsetof(TxPolicyView, packetType) == 12
  doAssert offsetof(TxPolicyView, controlInfo) == 16
  doAssert offsetof(TxPolicyView, retryRate) == 20
  doAssert offsetof(TxPolicyView, txPower) == 36
  doAssert offsetof(TxPolicyView, edcaParam0) == 52
  doAssert offsetof(TxPolicyView, edcaParam1) == 56
  doAssert sizeof(MichaelMicContextView) == 16
  doAssert offsetof(MichaelMicContextView, left) == 0
  doAssert offsetof(MichaelMicContextView, right) == 4
  doAssert offsetof(MichaelMicContextView, pending) == 8
  doAssert offsetof(MichaelMicContextView, nBytes) == 12
  doAssert offsetof(ApmTxDescPsView, staPeer) == 4
  doAssert offsetof(ApmTxDescPsView, staInstNbr) == 39
  doAssert offsetof(ApmTxDescPsView, tid) == 46
  doAssert offsetof(ApmTxDescPsView, deliveryPolicy) == 47
  doAssert offsetof(ApmTxDescPsView, subtype) == 49
  doAssert offsetof(ApmTxDescPsView, postponeFlags) == 50
  doAssert offsetof(ApmTxDescPsView, pendingCount) == 68
  doAssert offsetof(ApmTxDescPsView, staDesc) == 108
  doAssert offsetof(HostTxDescView, queueFirst) == 8
  doAssert offsetof(HostTxDescView, link) == 0
  doAssert offsetof(HostTxDescView, descWord4) == 4
  doAssert offsetof(HostTxDescView, seqPassthrough) == 12
  doAssert offsetof(HostTxDescView, cfmDst) == 16
  doAssert offsetof(HostTxDescView, da) == 20
  doAssert offsetof(HostTxDescView, sa) == 26
  doAssert offsetof(HostTxDescView, frameLen) == 32
  doAssert offsetof(HostTxDescView, pnScratch) == 34
  doAssert offsetof(HostTxDescView, seqAssigned) == 42
  doAssert offsetof(HostTxDescView, staIdx) == 46
  doAssert offsetof(HostTxDescView, vifIdx) == 47
  doAssert offsetof(HostTxDescView, hostVifType) == 48
  doAssert offsetof(HostTxDescView, staInfoIdx) == 49
  doAssert offsetof(HostTxDescView, bufferPtrs) == 52
  doAssert offsetof(HostTxDescView, bufferLens) == 68
  doAssert offsetof(HostTxDescView, pendingMacTime) == 84
  doAssert offsetof(HostTxDescView, policy) == 88
  doAssert offsetof(HostTxDescView, seqOut) == 96
  doAssert offsetof(HostTxDescView, hdrLen) == 98
  doAssert offsetof(HostTxDescView, qosExtLen) == 99
  doAssert offsetof(HostTxDescView, secTailLen) == 100
  doAssert offsetof(HostTxDescView, dmaLink) == 104
  doAssert offsetof(HostTxDescView, bufDesc) == 108
  doAssert offsetof(HostTxDescView, hwDesc) == 112
  doAssert offsetof(HostTxDescView, aggDescPtr) == 116
  doAssert offsetof(HostTxDescView, retryCount) == 172
  doAssert offsetof(HostTxDescView, lifetime) == 176
  doAssert offsetof(HostTxDescView, txFlags) == 180
  doAssert offsetof(HostTxDescView, aggDescStorage) == 188
  doAssert offsetof(HostTxDescView, cfmStatus) == 204
  doAssert offsetof(HostTxDescView, callback) == 208
  doAssert offsetof(HostTxDescView, callbackArg) == 212
  doAssert offsetof(HostTxDescView, usedFlag) == 216
  doAssert offsetof(HostTxDescView, postponeFlag) == 217
  doAssert offsetof(HostTxDescView, retryFlag) == 218
  doAssert sizeof(TxlFrameDescSlotView) == 220
  doAssert offsetof(TxlFrameDescSlotView, desc) == 0
  doAssert offsetof(HostTxHwDescView, txConfirmDescPtr) == 0
  doAssert offsetof(HostTxHwDescView, magic) == 4
  doAssert offsetof(HostTxHwDescView, secondaryThdPtr) == 8
  doAssert offsetof(HostTxHwDescView, txHwReserved12) == 12
  doAssert offsetof(HostTxHwDescView, status) == 16
  doAssert offsetof(HostTxHwDescView, payloadStart) == 20
  doAssert offsetof(HostTxHwDescView, payloadEnd) == 24
  doAssert offsetof(HostTxHwDescView, frameLen) == 28
  doAssert offsetof(HostTxHwDescView, txHwReserved32) == 32
  doAssert offsetof(HostTxHwDescView, retryLimitControl) == 36
  doAssert offsetof(HostTxHwDescView, chainedThd) == 40
  doAssert offsetof(HostTxHwDescView, txHwReserved44) == 44
  doAssert offsetof(HostTxHwDescView, txHwReserved48) == 48
  doAssert offsetof(HostTxHwDescView, txHwReserved52) == 52
  doAssert offsetof(HostTxHwDescView, ackPolicyControl) == 56
  doAssert offsetof(HostTxHwDescView, controlFlags) == 60
  doAssert offsetof(HostTxHwDescView, confirmStatus) == 64
  doAssert sizeof(TxlFrameHwDescSlotView) == 72
  doAssert offsetof(TxlFrameHwDescSlotView, desc) == 0
  doAssert sizeof(HostTxThdEntryView) == 20
  doAssert offsetof(HostTxThdEntryView, flags) == 16
  doAssert sizeof(HostTxThdConfirmView) == 20
  doAssert offsetof(HostTxThdConfirmView, confirmType) == 12
  doAssert offsetof(HostTxThdConfirmView, flags) == 16
  doAssert sizeof(TxDumpRateDescView) == 52
  doAssert offsetof(TxDumpRateDescView, next) == 16
  doAssert offsetof(TxDumpRateDescView, policy0) == 20
  doAssert offsetof(TxDumpRateDescView, policy1) == 36
  doAssert sizeof(TxDumpBufferDescView) == 12
  doAssert offsetof(TxDumpBufferDescView, next) == 4
  doAssert offsetof(TxDumpBufferDescView, word8) == 8
  doAssert sizeof(HostTxMicScratchView) == 32
  doAssert offsetof(HostTxMicScratchView, magic) == 0
  doAssert offsetof(HostTxMicScratchView, micLInit) == 4
  doAssert offsetof(HostTxMicScratchView, dataPtr) == 8
  doAssert offsetof(HostTxMicScratchView, endPtr) == 12
  doAssert offsetof(HostTxMicScratchView, pending) == 16
  doAssert offsetof(HostTxMicScratchView, data) == 20
  doAssert sizeof(CfgApiElementEntryView) == 28
  doAssert offsetof(CfgApiElementEntryView, id) == 0
  doAssert offsetof(CfgApiElementEntryView, subId) == 4
  doAssert offsetof(CfgApiElementEntryView, typeId) == 6
  doAssert offsetof(CfgApiElementEntryView, name) == 8
  doAssert offsetof(CfgApiElementEntryView, data) == 12
  doAssert offsetof(CfgApiElementEntryView, setHandler) == 16
  doAssert offsetof(HostTxLinkDescView, headerLen) == 4
  doAssert offsetof(HostTxLinkDescView, headerThd) == 72
  doAssert offsetof(HostTxLinkDescView, payloadThd) == 92
  doAssert offsetof(HostTxLinkDescView, rateTemplate) == 256
  doAssert offsetof(HostTxLinkDescView, ackPolicyControl) == 308
  doAssert offsetof(HostTxLinkDescView, retryLimitControl) == 312
  doAssert offsetof(HostTxLinkDescView, micScratch) == 316
  doAssert offsetof(HostTxLinkDescView, macHeader) == 348
  doAssert sizeof(TxlFrameLinkSlotView) == 860
  doAssert offsetof(HostTxInternalLinkNodeView, next) == 16
  doAssert offsetof(HostTxInternalLinkNodeView, txDesc) == 20
  doAssert offsetof(HostTxInternalLinkNodeView, headerThd) == 72
  doAssert offsetof(HostTxInternalLinkNodeView, payloadThd) == 92
  doAssert offsetof(HostTxInternalLinkNodeView, rateTemplate) == 256
  doAssert offsetof(HostTxInternalLinkNodeView, ackPolicyControl) == 308
  doAssert offsetof(HostTxInternalLinkNodeView, retryLimitControl) == 312
  doAssert offsetof(HostTxInternalLinkNodeView, micScratch) == 316
  doAssert offsetof(HostTxInternalLinkNodeView, macHeader) == 348
  doAssert offsetof(HostTxBufferedLinkView, headerLen) == 4
  doAssert offsetof(HostTxBufferedLinkView, padLen) == 8
  doAssert offsetof(HostTxBufferedLinkView, next) == 16
  doAssert offsetof(HostTxBufferedLinkView, txDesc) == 20
  doAssert offsetof(HostTxBufferedLinkView, headerThd) == 72
  doAssert offsetof(HostTxBufferedLinkView, payloadThd) == 92
  doAssert offsetof(HostTxBufferedLinkView, userIdx) == 252
  doAssert offsetof(HostTxBufferedLinkView, rateTemplate) == 256
  doAssert offsetof(HostTxBufferedLinkView, ackPolicyControl) == 308
  doAssert offsetof(HostTxBufferedLinkView, retryLimitControl) == 312
  doAssert offsetof(HostTxBufferedLinkView, micScratch) == 316
  doAssert offsetof(HostTxBufferedLinkView, macHeader) == 348
  doAssert sizeof(HostTxAuxWordsView) == 8
  doAssert offsetof(HostTxAuxWordsView, rateConfig) == 0
  doAssert offsetof(HostTxAuxWordsView, navValue) == 4
  doAssert sizeof(HostTxRateTemplateView) == 52
  doAssert offsetof(HostTxRateTemplateView, rateWord) == 20
  doAssert offsetof(HostTxRateTemplateView, retryRateControl0) == 24
  doAssert offsetof(HostTxRateTemplateView, retryRateControl1) == 28
  doAssert offsetof(HostTxRateTemplateView, retryRateControl2) == 32
  doAssert offsetof(HostTxRateTemplateView, txPower) == 36
  doAssert offsetof(HostTxRateTemplateView, retryTxPowerControl0) == 40
  doAssert offsetof(HostTxRateTemplateView, retryTxPowerControl1) == 44
  doAssert offsetof(HostTxRateTemplateView, retryTxPowerControl2) == 48
  doAssert sizeof(PsPollFrameHeaderView) == 16
  doAssert offsetof(PsPollFrameHeaderView, bssid) == 4
  doAssert offsetof(PsPollFrameHeaderView, transmitterAddr) == 10
  doAssert sizeof(TxBufferControlView) == 60
  doAssert offsetof(TxBufferControlView, magic) == 0
  doAssert offsetof(TxBufferControlView, ntxConfig) == 4
  doAssert offsetof(TxBufferControlView, bwMask) == 8
  doAssert offsetof(TxBufferControlView, pendingCount) == 12
  doAssert offsetof(TxBufferControlView, policyWord) == 16
  doAssert offsetof(TxBufferControlView, rateWord) == 20
  doAssert offsetof(TxBufferControlView, retryRateControl0) == 24
  doAssert offsetof(TxBufferControlView, retryRateControl1) == 28
  doAssert offsetof(TxBufferControlView, retryRateControl2) == 32
  doAssert offsetof(TxBufferControlView, txPower) == 36
  doAssert offsetof(TxBufferControlView, retryTxPowerControl0) == 40
  doAssert offsetof(TxBufferControlView, retryTxPowerControl1) == 44
  doAssert offsetof(TxBufferControlView, retryTxPowerControl2) == 48
  doAssert offsetof(TxBufferControlView, ackPolicyControl) == 52
  doAssert offsetof(TxBufferControlView, retryLimitControl) == 56
  doAssert sizeof(TxlFramePayloadSlotView) == 60
  doAssert offsetof(TxlFramePayloadSlotView, desc) == 0
  doAssert sizeof(TxlFrameHwCfmSlotView) == 20
  doAssert sizeof(TxlBackupQueueView) == 8
  doAssert offsetof(TxlBackupQueueView, first) == 0
  doAssert offsetof(TxlBackupQueueView, last) == 4
  doAssert offsetof(TxlBufferEnvView, backupQueues) == 180
  doAssert offsetof(TxlBufferEnvView, backupQueues) +
    4 * sizeof(TxlBackupQueueView) == 212
  doAssert offsetof(TxlBufferEnvView, backupQueues) +
    4 * sizeof(TxlBackupQueueView) + offsetof(TxlBackupQueueView, last) == 216
  doAssert sizeof(MacDataFrameHeaderView) == 24
  doAssert offsetof(MacDataFrameHeaderView, frameControl) == 0
  doAssert offsetof(MacDataFrameHeaderView, addr1) == 4
  doAssert offsetof(MacDataFrameHeaderView, addr2) == 10
  doAssert offsetof(MacDataFrameHeaderView, addr3) == 16
  doAssert offsetof(MacDataFrameHeaderView, seqCtrl) == 22
  doAssert sizeof(MacQosDataFrameHeaderView) == 26
  doAssert offsetof(MacQosDataFrameHeaderView, qosCtrl) == 24
  doAssert sizeof(MacQos4AddrFrameHeaderView) == 32
  doAssert offsetof(MacQos4AddrFrameHeaderView, addr4) == 24
  doAssert offsetof(MacQos4AddrFrameHeaderView, qosCtrl) == 30
  doAssert sizeof(MacCtsFrameHeaderView) == 10
  doAssert offsetof(MacCtsFrameHeaderView, receiverAddr) == 4
  doAssert sizeof(SaQueryActionBodyView) == 4
  doAssert offsetof(SaQueryActionBodyView, category) == 0
  doAssert offsetof(SaQueryActionBodyView, action) == 1
  doAssert offsetof(SaQueryActionBodyView, transId) == 2
  doAssert sizeof(TxSecurityHeaderView) == 8
  doAssert offsetof(TxSecurityHeaderView, w0) == 0
  doAssert offsetof(TxSecurityHeaderView, w3) == 6
  doAssert sizeof(TxPnScratchView) == 6
  doAssert offsetof(TxPnScratchView, lo) == 0
  doAssert offsetof(TxPnScratchView, mid) == 2
  doAssert offsetof(TxPnScratchView, hi) == 4
  doAssert sizeof(LlcSnapHeaderView) == 8
  doAssert offsetof(LlcSnapHeaderView, dsap) == 0
  doAssert offsetof(LlcSnapHeaderView, oui) == 3
  doAssert offsetof(LlcSnapHeaderView, ethertype) == 6
  doAssert sizeof(MacFrameControlView) == 2
  doAssert offsetof(MacFrameControlView, frameControl) == 0
  doAssert offsetof(StaInfoView, vif) == STA_VIF_PTR_OFF
  doAssert offsetof(StaInfoView, macAddr) == 4
  doAssert offsetof(StaInfoView, registerWord0) == 12
  doAssert offsetof(StaInfoView, registerWord1) == 16
  doAssert offsetof(StaInfoView, connectionStart) == 20
  doAssert offsetof(StaInfoView, initialRateConfig) == 24
  doAssert offsetof(StaInfoView, rateSet) == 32
  doAssert offsetof(StaInfoView, listenWindowDuration) == 34
  doAssert offsetof(StaInfoView, aid) == 36
  doAssert offsetof(StaInfoView, phyBwMax) == 38
  doAssert offsetof(StaInfoView, instNbr) == 39
  doAssert offsetof(StaInfoView, infoIdx) == STA_INFO_IDX_OFF
  doAssert offsetof(StaInfoView, psMode) == 41
  doAssert offsetof(StaInfoView, valid) == 42
  doAssert offsetof(StaInfoView, extFlag) == 43
  doAssert offsetof(StaInfoView, paramFlag) == 44
  doAssert offsetof(StaInfoView, psStatus) == 48
  doAssert offsetof(StaInfoView, beaconTimeOffset) == 52
  doAssert offsetof(StaInfoView, rateWord) == 70
  doAssert offsetof(StaInfoView, rxNss) == 72
  doAssert offsetof(StaInfoView, trafficFlags) == 73
  doAssert offsetof(StaInfoView, reserved74) == 74
  doAssert offsetof(StaInfoView, keyArea) == 80
  doAssert offsetof(StaInfoView, pnLow) == 208
  doAssert offsetof(StaInfoView, pnHigh) == 212
  doAssert offsetof(StaInfoView, keyTail) == 216
  doAssert offsetof(StaInfoView, keyType) == 232
  doAssert offsetof(StaInfoView, cipherSuite) == 233
  doAssert offsetof(StaInfoView, hwKeyIdx) == 234
  doAssert offsetof(StaInfoView, keyInstalled) == 235
  doAssert offsetof(StaInfoView, keyFlags) == 236
  doAssert offsetof(StaInfoView, keyHolder) == 240
  doAssert offsetof(StaInfoView, keyMat) == 244
  doAssert offsetof(StaInfoView, supportedRates) == 248
  doAssert offsetof(StaInfoView, vhtCaps) == 264
  doAssert offsetof(StaInfoView, capabilityFlags) == STA_RATE_INFO_FLAGS_OFF
  doAssert offsetof(StaInfoView, bwConfigState) == 312
  doAssert offsetof(StaInfoView, nssBwMax) == STA_NSS_BW_MAX_OFF
  doAssert offsetof(StaInfoView, psState) == 314
  doAssert offsetof(StaInfoView, uapsdBitmap) == 315
  doAssert offsetof(StaInfoView, htVhtConfig) == 316
  doAssert offsetof(StaInfoView, txPolicy) == STA_TX_POLICY_PTR_OFF
  doAssert offsetof(StaInfoView, rcStats) == STA_RC_STATS_PTR_OFF
  doAssert offsetof(StaInfoView, aggregationLength) == 328
  doAssert offsetof(StaInfoView, supportedRatesBitmap) == STA_SUPP_RATES_OFF
  doAssert offsetof(StaInfoView, mmFlagsBytes) == STA_RC_FLAGS_OFF
  doAssert offsetof(StaInfoView, reserved338) == 338
  doAssert offsetof(StaInfoView, postponedList) == 356
  doAssert offsetof(StaInfoView, apmConnectTime) == 364
  doAssert sizeof(StaInfoView) == STA_ENTRY_SIZE
  doAssert offsetof(StaTxSequenceOverlay, seqCounter) == 28
  doAssert offsetof(RxuQosSeqCacheEntryView, seqCtrl) == 0
  doAssert sizeof(RxuQosSeqCacheEntryView) == 184
  doAssert offsetof(RxuQosSeqCacheTableOverlay, entries) == 169 * 184
  doAssert sizeof(ApSelfStaStartOverlay) == 335
  doAssert offsetof(ApSelfStaStartOverlay, status) == 4
  doAssert offsetof(ApSelfStaStartOverlay, infoIdx) == 40
  doAssert offsetof(ApSelfStaStartOverlay, valid) == 42
  doAssert offsetof(ApSelfStaStartOverlay, vifType) == 72
  doAssert offsetof(ApSelfStaStartOverlay, rateSeed) == 248
  doAssert offsetof(ApSelfStaStartOverlay, rcFlags) == 334
  doAssert sizeof(StaBandwidthOverlay) == 56
  doAssert offsetof(StaBandwidthOverlay, rateInfoPtr) == 0
  doAssert offsetof(StaBandwidthOverlay, primaryBw) == 4
  doAssert offsetof(StaBandwidthOverlay, bwField) == 6
  doAssert offsetof(StaBandwidthOverlay, secondaryBw) == 54
  doAssert sizeof(StaMgmtRegisterParamView) == 25
  doAssert offsetof(StaMgmtRegisterParamView, vif) == 0
  doAssert offsetof(StaMgmtRegisterParamView, rateSet) == 4
  doAssert offsetof(StaMgmtRegisterParamView, macAddr) == 6
  doAssert offsetof(StaMgmtRegisterParamView, phyBwMax) == 12
  doAssert offsetof(StaMgmtRegisterParamView, instNbr) == 13
  doAssert offsetof(StaMgmtRegisterParamView, extFlag) == 14
  doAssert offsetof(StaMgmtRegisterParamView, registerWord0) == 16
  doAssert offsetof(StaMgmtRegisterParamView, registerWord1) == 20
  doAssert offsetof(StaMgmtRegisterParamView, paramFlag) == 24
  doAssert sizeof(ChanEnvView) == 132
  doAssert offsetof(ChanEnvView, currentCtxt) == 32
  doAssert offsetof(ChanEnvView, scheduledCtxt) == 36
  doAssert offsetof(ChanEnvView, scanCtxt) == 40
  doAssert offsetof(ChanEnvView, tbttSwitchCallback) == 48
  doAssert offsetof(ChanEnvView, tbttDeferredSlot) == 52
  doAssert offsetof(ChanEnvView, cdeCallback) == 64
  doAssert offsetof(ChanEnvView, cdeArg) == 68
  doAssert offsetof(ChanEnvView, nextChanTimestamp) == 72
  doAssert offsetof(ChanEnvView, ctxtOpCallback) == 80
  doAssert offsetof(ChanEnvView, remainingTimeTarget) == 88
  doAssert offsetof(ChanEnvView, connLessDelayCallback) == 96
  doAssert offsetof(ChanEnvView, timerState) == 104
  doAssert offsetof(ChanEnvView, slotPeriod) == 108
  doAssert offsetof(ChanEnvView, flags) == 120
  doAssert offsetof(ChanEnvView, ctxtCount) == 124
  doAssert sizeof(RxuCntrlEnvView) == 96
  doAssert offsetof(RxuCntrlEnvView, frameCtrl) == 0
  doAssert offsetof(RxuCntrlEnvView, seqCtrl) == 2
  doAssert offsetof(RxuCntrlEnvView, seqNum) == 4
  doAssert offsetof(RxuCntrlEnvView, fragNum) == 6
  doAssert offsetof(RxuCntrlEnvView, tid) == 7
  doAssert offsetof(RxuCntrlEnvView, machdrLen) == 8
  doAssert offsetof(RxuCntrlEnvView, staIdx) == 9
  doAssert offsetof(RxuCntrlEnvView, vifIdx) == 10
  doAssert offsetof(RxuCntrlEnvView, dstIdx) == 11
  doAssert offsetof(RxuCntrlEnvView, secInfo0) == 16
  doAssert offsetof(RxuCntrlEnvView, secInfo1) == 20
  doAssert offsetof(RxuCntrlEnvView, hwRxhdr) == 24
  doAssert offsetof(RxuCntrlEnvView, secKeyPtr) == 32
  doAssert offsetof(RxuCntrlEnvView, da) == 36
  doAssert offsetof(RxuCntrlEnvView, sa) == 42
  doAssert offsetof(RxuCntrlEnvView, secFlags) == 48
  doAssert offsetof(RxuCntrlEnvView, meshFlag) == 49
  doAssert offsetof(RxuCntrlEnvView, stripLen) == 50
  doAssert offsetof(RxuCntrlEnvView, deferredList) == 56
  doAssert offsetof(RxuCntrlEnvView, uploadList) == 64
  doAssert offsetof(RxuCntrlEnvView, pendingList) == 72
  doAssert offsetof(RxuCntrlEnvView, freeList) == 80
  doAssert offsetof(RxuCntrlEnvView, bssidSeq) == 94
  doAssert sizeof(CcmpSecurityHeaderView) == 8
  doAssert offsetof(CcmpSecurityHeaderView, keyId) == 3
  doAssert sizeof(TkipSecurityHeaderView) == 8
  doAssert offsetof(TkipSecurityHeaderView, keyId) == 3
  doAssert sizeof(RxlCntrlEnvView) == 28
  doAssert offsetof(RxlCntrlEnvView, queue) == 0
  doAssert offsetof(RxlCntrlEnvView, submittedHead) == 8
  doAssert offsetof(RxlCntrlEnvView, submittedTail) == 12
  doAssert offsetof(RxlCntrlEnvView, currentHd) == 16
  doAssert offsetof(RxlCntrlEnvView, pendingMpduCount) == 20
  doAssert offsetof(RxlCntrlEnvView, processingFlag) == 24
  doAssert sizeof(RxHwDescEnvView) == 8
  doAssert offsetof(RxHwDescEnvView, pdTail) == 0
  doAssert offsetof(RxHwDescEnvView, pdCurrent) == 4
  doAssert sizeof(RxHeaderHwDescView) == 100
  doAssert offsetof(RxHeaderHwDescView, next) == 4
  doAssert offsetof(RxHeaderHwDescView, bufferAddr) == 8
  doAssert offsetof(RxHeaderHwDescView, swDesc) == 12
  doAssert offsetof(RxHeaderHwDescView, nextThd) == 16
  doAssert offsetof(RxHeaderHwDescView, status) == 20
  doAssert offsetof(RxHeaderHwDescView, rxStatusWord24) == 24
  doAssert offsetof(RxHeaderHwDescView, statusHalf) == 28
  doAssert offsetof(RxHeaderHwDescView, statusHalf2) == 30
  doAssert offsetof(RxHeaderHwDescView, rxVectorWord32) == 32
  doAssert offsetof(RxHeaderHwDescView, rxVectorWord36) == 36
  doAssert offsetof(RxHeaderHwDescView, word44) == 44
  doAssert offsetof(RxHeaderHwDescView, rxVectorWord60) == 60
  doAssert offsetof(RxHeaderHwDescView, flags) == 64
  doAssert offsetof(RxHeaderHwDescView, usedFlag) == 96
  doAssert sizeof(RxSwTableDescView) == 24
  doAssert offsetof(RxSwTableDescView, firstHeaderDesc) == 4
  doAssert sizeof(RxFrameBufferRefView) == 28
  doAssert offsetof(RxFrameBufferRefView, frameData) == 24
  doAssert sizeof(RxFrameBufferChainView) == 12
  doAssert offsetof(RxFrameBufferChainView, next) == 4
  doAssert offsetof(RxFrameBufferChainView, frameData) == 8
  doAssert sizeof(RxDmaProgressDescView) == 24
  doAssert offsetof(RxDmaProgressDescView, next) == 4
  doAssert offsetof(RxDmaProgressDescView, status) == 16
  doAssert offsetof(RxDmaProgressDescView, usedFlag) == 20
  doAssert sizeof(RxMicFailureIndView) == 24
  doAssert offsetof(RxMicFailureIndView, pnLow) == 8
  doAssert offsetof(RxMicFailureIndView, tid) == 16
  doAssert sizeof(RxuMgtIndMsgView) == 32
  doAssert offsetof(RxuMgtIndMsgView, frameCtrl) == 2
  doAssert offsetof(RxuMgtIndMsgView, vifIdx) == 7
  doAssert offsetof(RxuMgtIndMsgView, timestampLow) == 16
  doAssert offsetof(RxuMgtIndMsgView, phyVector11) == 24
  doAssert offsetof(RxuMgtIndMsgView, body) == 32
  doAssert offsetof(RxSwDescView, bufferChain) == 8
  doAssert offsetof(RxSwDescView, firstDmaDesc) == 4
  doAssert offsetof(RxSwDescView, payloadLenHalf) == 28
  doAssert offsetof(RxSwDescView, timestampLow) == 32
  doAssert offsetof(RxSwDescView, timestampHigh) == 36
  doAssert offsetof(RxSwDescView, phyVector) == 40
  doAssert offsetof(RxSwDescView, hwFlags) == 64
  doAssert offsetof(RxSwDescView, channelInfo) == 68
  doAssert offsetof(RxSwDescView, frameControlFlags) == 76
  doAssert offsetof(RxSwDescView, bufferOffset) == 84
  doAssert offsetof(RxSwDescView, uploadDone) == 96
  doAssert sizeof(RxMpduDescView) == 22
  doAssert offsetof(RxMpduDescView, swDesc) == 4
  doAssert offsetof(RxMpduDescView, prevDesc) == 12
  doAssert offsetof(RxMpduDescView, curDesc) == 16
  doAssert offsetof(RxMpduDescView, descFlag) == 20
  doAssert offsetof(RxMpduDescView, descCount) == 21
  doAssert offsetof(RxPayloadHwDescView, next) == 4
  doAssert offsetof(RxPayloadHwDescView, bufferAddr) == 8
  doAssert offsetof(RxPayloadHwDescView, bufferEnd) == 12
  doAssert offsetof(RxPayloadHwDescView, status) == 16
  doAssert offsetof(RxPayloadHwDescView, usedFlag) == 20
  doAssert offsetof(RxPayloadHwDescView, bufferStart) == 24
  doAssert offsetof(RxPayloadHwDescView, frameLen) == 28
  doAssert sizeof(RxPayloadHwDescView) == 52
  doAssert sizeof(RxPayloadBufferView) == 1736
  doAssert offsetof(RxFrameBufferRefView, frameData) == 24
  doAssert sizeof(RxFrameBufferChainView) == 12
  doAssert offsetof(RxFrameBufferChainView, next) == 4
  doAssert offsetof(RxFrameBufferChainView, frameData) == 8
  doAssert sizeof(RxEthernetRewriteHeaderView) == 14
  doAssert offsetof(RxEthernetRewriteHeaderView, sa) == 6
  doAssert offsetof(RxEthernetRewriteHeaderView, ethertype) == 12
  doAssert sizeof(RxUploadDmaArrayView) == 40
  doAssert offsetof(RxUploadDmaArrayView, bufferAddrs) == 0
  doAssert offsetof(RxUploadDmaArrayView, lengths) == 32
  doAssert sizeof(RxuUploadEnvView) == 28
  doAssert offsetof(RxuUploadEnvView, uploadCount) == 20
  doAssert sizeof(RxlHwdescCallbackEnvView) == 28
  doAssert offsetof(RxlHwdescCallbackEnvView, getStatus) == 20
  doAssert offsetof(RxlHwdescCallbackEnvView, clean) == 24
  doAssert offsetof(RxlSubmittedDescView, next) == 4
  doAssert offsetof(RxlSubmittedDescView, bufferChain) == 8
  doAssert offsetof(RxlSubmittedDescView, swDesc) == 12
  doAssert offsetof(RxlSubmittedDescView, status) == 64
  doAssert sizeof(BeaconRxDescView) == 52
  doAssert offsetof(BeaconRxDescView, payloadDesc) == 8
  doAssert offsetof(BeaconRxDescView, frameLen) == 28
  doAssert offsetof(BeaconRxDescView, rssi) == 51
  doAssert sizeof(BeaconPayloadDescView) == 12
  doAssert offsetof(BeaconPayloadDescView, frameData) == 8
  doAssert sizeof(BeaconFrameFixedView) == 36
  doAssert offsetof(BeaconFrameFixedView, tsfLow) == 24
  doAssert offsetof(BeaconFrameFixedView, beaconInterval) == 32
  doAssert offsetof(BeaconFrameFixedView, body) == 36
  doAssert sizeof(ProbeRspFixedBodyView) == 12
  doAssert offsetof(ProbeRspFixedBodyView, beaconInterval) == 8
  doAssert offsetof(ProbeRspFixedBodyView, capabilityInfo) == 10
  doAssert offsetof(ProbeRspFixedBodyView, body) == 12
  doAssert sizeof(HtMcsNssPrefixView) == 4

template keMsgHdrFromPayload*(param: pointer): ptr KeMsgHdr =
  let envelope = cast[ptr KeMsgEnvelope](
    cast[uint](param) - offsetof(KeMsgEnvelope, payload).uint)
  addr envelope.header

template keMsgPayload*(hdr: ptr KeMsgHdr): pointer =
  let envelope = cast[ptr KeMsgEnvelope](hdr)
  cast[pointer](addr envelope.payload[0])

template ipcPayloadWordStreamAt(payload: pointer): ptr IpcPayloadWordStreamView =
  cast[ptr IpcPayloadWordStreamView](payload)

proc copyIpcPayloadWords(dst, src: pointer; byteLen: uint32) {.inline.} =
  let dstWords = ipcPayloadWordStreamAt(dst)
  let srcWords = ipcPayloadWordStreamAt(src)
  let wordCount = byteLen shr 2
  for wordIdx in 0'u32 ..< wordCount:
    dstWords.words[wordIdx] = srcWords.words[wordIdx]
  let tailStart = wordCount shl 2
  if tailStart < byteLen:
    let dstBytes = cast[ptr UncheckedArray[uint8]](dst)
    let srcBytes = cast[ptr UncheckedArray[uint8]](src)
    for byteIdx in tailStart ..< byteLen:
      dstBytes[byteIdx] = srcBytes[byteIdx]

template notifierNodeView(node: ptr CoListHdr): ptr NotifierNodeView =
  cast[ptr NotifierNodeView](node)

template elementNotifyContextAt(ctx: pointer): ptr ElementNotifyContextView =
  cast[ptr ElementNotifyContextView](ctx)

template keMsgExternalPayload*(param: pointer): pointer =
  cast[pointer](cast[uint](param) - 8'u)

template encodedArgU8*(p: pointer): uint8 =
  cast[uint8](cast[uint](p) and 0xFF'u)

template encodedArgU*(p: pointer): uint =
  cast[uint](p)

template encodedArgU32*(p: pointer): uint32 =
  cast[uint32](cast[uint](p))

template pointerAddrU32*(p: pointer): uint32 =
  cast[uint32](cast[uint](p))

proc debugLoadLe32(p: pointer): uint32 {.inline.} =
  if p == nil:
    return 0
  let b = cast[ptr UncheckedArray[uint8]](p)
  b[0].uint32 or (b[1].uint32 shl 8) or
    (b[2].uint32 shl 16) or (b[3].uint32 shl 24)

proc wifiRamPointer(p: pointer): bool {.inline.} =
  let a = pointerAddrU32(p)
  ((a >= OcramBase.uint32) and (a < (OcramBase + OcramSize).uint32)) or
    ((a >= OcramCachedBase.uint32) and (a < (OcramCachedBase + OcramSize).uint32)) or
    ((a >= WramBase.uint32) and (a < (WramBase + WramSize).uint32)) or
    ((a >= WramCachedBase.uint32) and (a < (WramCachedBase + WramSize).uint32))

template mmTimerAt(p: pointer): ptr MmTimerView =
  cast[ptr MmTimerView](p)

template mmTimerAt(p: ptr CoListHdr): ptr MmTimerView =
  cast[ptr MmTimerView](p)

template mmTimerHdr(t: ptr MmTimerView): ptr CoListHdr =
  cast[ptr CoListHdr](t)

template txControlEnv(): ptr TxControlEnvView =
  cast[ptr TxControlEnvView](addr txl_cntrl_env[0])

template txControlAc(idx: uint32): ptr TxControlAcView =
  addr txControlEnv().ac[idx]

template txCfmEnv(): ptr TxCfmEnvView =
  cast[ptr TxCfmEnvView](addr txl_cfm_env[0])

template txCfmList(idx: uint32): ptr CoList =
  addr txCfmEnv().lists[idx]

template machwTxQueueRegs(): ptr MachwTxQueueRegsView =
  cast[ptr MachwTxQueueRegsView](MACHW_INTC_BASE)

template machwRxDmaRegs(): ptr MachwRxDmaRegsView =
  cast[ptr MachwRxDmaRegsView](MACHW_INTC_BASE)

proc waitRegMaskClear(reg: uint, mask: uint32,
                      limit: uint32 = 100_000'u32): bool

const MACHW_SECURITY_CTRL_REG = MACHW_BASE + 0x0C4'u

template machwSecurityRegs(): ptr MachwSecurityRegsView =
  cast[ptr MachwSecurityRegsView](MACHW_BASE)

template wlanCoexRegs(): ptr WlanCoexRegsView =
  cast[ptr WlanCoexRegsView](MACHW_BCN_STATUS_REG)

template ptaCoexRegs(): ptr PtaCoexRegsView =
  cast[ptr PtaCoexRegsView](COEX_BASE)

proc wlanCoexControl(): uint32 {.inline.} =
  volatileLoad(addr wlanCoexRegs().control)

proc wlanCoexPti(): uint32 {.inline.} =
  volatileLoad(addr wlanCoexRegs().pti)

proc wlanCoexStatus(): uint32 {.inline.} =
  volatileLoad(addr wlanCoexRegs().status)

proc wlanCoexWriteControl(value: uint32) {.inline.} =
  volatileStore(addr wlanCoexRegs().control, value)

proc wlanCoexWritePti(value: uint32) {.inline.} =
  volatileStore(addr wlanCoexRegs().pti, value)

proc ptaCoexControl(): uint32 {.inline.} =
  volatileLoad(addr ptaCoexRegs().control)

proc ptaCoexControl2(): uint32 {.inline.} =
  volatileLoad(addr ptaCoexRegs().control2)

proc ptaCoexMirror(): uint32 {.inline.} =
  volatileLoad(addr ptaCoexRegs().mirror)

proc ptaCoexWriteControl(value: uint32) {.inline.} =
  volatileStore(addr ptaCoexRegs().control, value)

proc ptaCoexWriteControl2(value: uint32) {.inline.} =
  volatileStore(addr ptaCoexRegs().control2, value)

proc ptaCoexWriteMirror(value: uint32) {.inline.} =
  volatileStore(addr ptaCoexRegs().mirror, value)

proc ptaCoexClear() {.inline.} =
  volatileStore(addr ptaCoexRegs().clear, 0'u32)

proc ptaCoexUpdateControl(keepMask, setMask: uint32) {.inline.} =
  ptaCoexWriteControl((ptaCoexControl() and keepMask) or setMask)

proc machwSecurityWriteAddress(lo, hi: uint32) {.inline.} =
  let regs = machwSecurityRegs()
  volatileStore(addr regs.dataLow, lo)
  volatileStore(addr regs.dataHigh, hi)

proc machwSecurityClearKeyMaterial() {.inline.} =
  let regs = machwSecurityRegs()
  for i in 0 ..< regs.keyMaterial.len:
    volatileStore(addr regs.keyMaterial[i], 0'u32)

proc machwSecurityWriteKeyMaterial(words: array[4, uint32]) {.inline.} =
  let regs = machwSecurityRegs()
  for i in 0 ..< regs.keyMaterial.len:
    volatileStore(addr regs.keyMaterial[i], words[i])

proc machwSecurityWriteControl(value: uint32) {.inline.} =
  volatileStore(addr machwSecurityRegs().control, value)

proc machwSecurityControl(): uint32 {.inline.} =
  volatileLoad(addr machwSecurityRegs().control)

proc machwSecurityKeyCount(): uint32 {.inline.} =
  volatileLoad(addr machwSecurityRegs().keyCount)

proc waitMachwSecurityControlClear(mask: uint32): bool {.inline.} =
  waitRegMaskClear(MACHW_SECURITY_CTRL_REG, mask)

proc machwTxStatus(): uint32 {.inline.} =
  volatileLoad(addr machwTxQueueRegs().txStatus)

proc machwTxReadyAck(bits: uint32) {.inline.} =
  volatileStore(addr machwTxQueueRegs().readyAck, bits)

proc machwTxTrigger(bits: uint32) {.inline.} =
  volatileStore(addr machwTxQueueRegs().txTrigger, bits)

proc machwTxDmaStatus(): uint32 {.inline.} =
  volatileLoad(addr machwTxQueueRegs().dmaStatus)

proc machwTxAggActive(): uint32 {.inline.} =
  volatileLoad(addr machwTxQueueRegs().txAggActive)

proc machwTxAggSet(bits: uint32) {.inline.} =
  volatileStore(addr machwTxQueueRegs().txAggSet, bits)

proc machwTxAggActiveSet(bits: uint32) {.inline.} =
  volatileStore(addr machwTxQueueRegs().txAggActive, bits)

proc machwTxHeadReg(ac: uint32): ptr uint32 {.inline.} =
  let regs = machwTxQueueRegs()
  case ac
  of 0: addr regs.ac0Head
  of 1: addr regs.ac1Head
  of 2: addr regs.ac2Head
  of 3: addr regs.ac3Head
  of 4: addr regs.beaconHead
  else: nil

proc machwTxHeadValue(ac: uint32): uint32 {.inline.} =
  let reg = machwTxHeadReg(ac)
  if reg == nil:
    0'u32
  else:
    volatileLoad(reg)

proc machwTxSetHead(ac: uint32; thd: pointer) {.inline.} =
  let reg = machwTxHeadReg(ac)
  if reg != nil:
    volatileStore(reg, pointerAddrU32(thd))

proc machwRxDmaTrigger(bits: uint32) {.inline.} =
  volatileStore(addr machwRxDmaRegs().trigger, bits)

proc machwRxHdSubmittedHead(): uint32 {.inline.} =
  volatileLoad(addr machwRxDmaRegs().hdSubmittedHead)

proc machwRxPdSubmittedHead(): uint32 {.inline.} =
  volatileLoad(addr machwRxDmaRegs().pdSubmittedHead)

proc machwRxHwHdHead(): uint32 {.inline.} =
  volatileLoad(addr machwRxDmaRegs().hdHwHead)

proc machwRxHwPdHead(): uint32 {.inline.} =
  volatileLoad(addr machwRxDmaRegs().pdHwHead)

proc machwRxSetHdSubmittedHead(value: uint32) {.inline.} =
  volatileStore(addr machwRxDmaRegs().hdSubmittedHead, value)

proc machwRxSetPdSubmittedHead(value: uint32) {.inline.} =
  volatileStore(addr machwRxDmaRegs().pdSubmittedHead, value)

template txFrameEnv(): ptr TxFrameEnvView =
  cast[ptr TxFrameEnvView](addr txl_frame_env[0])

template meEnvView(): ptr MeEnvView =
  cast[ptr MeEnvView](addr me_env[0])

template meHtCapsPtr(me: ptr MeEnvView): pointer =
  addr me.htCaps[0]

template meChannelConfigView(): ptr MeChannelConfigView =
  cast[ptr MeChannelConfigView](addr meEnvView().chanConfig[0])

template meBeaconSequence(): ptr MeBeaconSequenceOverlay =
  cast[ptr MeBeaconSequenceOverlay](addr me_env[0])

template mmEnvView(): ptr MmEnvView =
  cast[ptr MmEnvView](addr mm_env[0])

template mmWmmParameterSource(): ptr MmWmmParameterSourceView =
  cast[ptr MmWmmParameterSourceView](addr mm_env[0])

template bcnEnvView(): ptr MmBcnEnvView =
  cast[ptr MmBcnEnvView](addr mm_bcn_env[0])

template beaconChangeReqAt(param: pointer): ptr BeaconChangeReqView =
  cast[ptr BeaconChangeReqView](param)

template beaconEndDesc(): ptr BeaconEndDescView =
  cast[ptr BeaconEndDescView](addr txl_bcn_end_desc[0])

template timDescView(): ptr TimDescView =
  cast[ptr TimDescView](addr txl_tim_desc[0])

template vifMgmtEnvView(): ptr VifMgmtEnvView =
  cast[ptr VifMgmtEnvView](addr vif_mgmt_env[0])

template vifMgmtHostapdOpsEnv(): ptr VifMgmtHostapdOpsEnvView =
  cast[ptr VifMgmtHostapdOpsEnvView](addr vif_mgmt_env[0])

template vifHostapdPrivAt(p: uint): ptr VifHostapdPrivView =
  cast[ptr VifHostapdPrivView](p)

template vifHostapdPriv(vif: ptr VifChannelView): ptr VifHostapdPrivView =
  vifHostapdPrivAt(cast[uint](vif))

template vifApProbeSsid(vif: ptr VifChannelView): ptr VifApProbeSsidOverlay =
  cast[ptr VifApProbeSsidOverlay](vif)

template hostapdOpsAt(p: pointer): ptr HostapdOpsView =
  cast[ptr HostapdOpsView](p)

template psEnvView(): ptr PsEnvView =
  cast[ptr PsEnvView](addr ps_env[0])

template psDozeEnvView(): ptr PsDozeEnvView =
  cast[ptr PsDozeEnvView](addr ps_env[0])

template smEnvView(): ptr SmEnvView =
  cast[ptr SmEnvView](addr sm_env[0])

template apmEnvView(): ptr ApmEnvView =
  cast[ptr ApmEnvView](addr apm_env[0])

template apmStaSlot(idx: uint): ptr ApmStaSlotOverlay =
  cast[ptr ApmStaSlotOverlay](cast[uint](addr apm_env[0]) + 80'u + idx * 16'u)

template connectInfoView(connInfo: pointer): ptr ConnectInfoView =
  cast[ptr ConnectInfoView](connInfo)

template connectInfoCredentials(connInfo: pointer): ptr ConnectInfoCredentialOverlay =
  cast[ptr ConnectInfoCredentialOverlay](connInfo)

template connectInfoChannelContext(connInfo: pointer): ptr ConnectInfoChannelContextOverlay =
  cast[ptr ConnectInfoChannelContextOverlay](connInfo)

template connectInfoAuthRetry(connInfo: pointer): ptr uint8 =
  addr connectInfoView(connInfo).authRetry

template connectInfoChannelHint(connInfo: pointer): pointer =
  cast[pointer](addr connectInfoView(connInfo).channelHint[0])

proc connectInfoChannelFrequency(ci: ptr ConnectInfoView): uint16 {.inline.} =
  uint16(ci.channelHint[0]) or (uint16(ci.channelHint[1]) shl 8)

proc connectInfoHasChannelHint(ci: ptr ConnectInfoView): bool {.inline.} =
  let freq = connectInfoChannelFrequency(ci)
  freq != 0'u16 and freq != 0xFFFF'u16

proc connectInfoSsidLen(ci: ptr ConnectInfoView): uint8 {.inline.} =
  if ci.ssidLen > 0 and ci.ssidLen <= 32:
    return ci.ssidLen
  var length: uint8 = 0
  while length < 32'u8 and ci.ssid[length.int] != 0'u8:
    inc length
  length

proc connectInfoFillSsidSlot(slot: ptr ScanSsidSlotView;
                             ci: ptr ConnectInfoView) {.inline.} =
  slot.length = 0
  for i in 0 ..< slot.data.len:
    slot.data[i] = 0
  let length = connectInfoSsidLen(ci)
  slot.length = length
  for i in 0 ..< length.int:
    slot.data[i] = ci.ssid[i]

proc vifChannelCenterFreq1(vif: ptr VifChannelView; fallback: uint16): uint16 {.inline.} =
  let freq = uint16(vif.channelFreqPair and 0xFFFF'u32)
  if freq == 0'u16: fallback else: freq

proc vifChannelCenterFreq2(vif: ptr VifChannelView): uint16 {.inline.} =
  uint16((vif.channelFreqPair shr 16) and 0xFFFF'u32)

proc lmacGateHalfword(value: uint16): uint16 {.inline.} =
  ((value and 0x00ff'u16) shl 8) or (value shr 8)

proc txFrameBaseMacLen(desc: ptr HostTxDescView): uint8 {.inline.} =
  if desc.staIdx == 0xFF'u8: 24'u8
  else: sizeof(MacQosDataFrameHeaderView).uint8

proc txFrameSnapLen(frameType: uint16): uint8 {.inline.} =
  if frameType > 1535'u16: sizeof(LlcSnapHeaderView).uint8
  else: 0'u8

proc txFrameSecLen(desc: ptr HostTxDescView; macLen, snapLen: uint8): uint8 {.inline.} =
  if desc.hdrLen > macLen + snapLen:
    desc.hdrLen - macLen - snapLen
  else:
    0'u8

proc txFrameBuildLayout(desc: ptr HostTxDescView; payloadStart: pointer;
                        frameType: uint16): TxFrameBuildLayout {.inline.} =
  let payload = cast[uint](payloadStart)
  result.macLen = txFrameBaseMacLen(desc)
  result.snapLen = txFrameSnapLen(frameType)
  result.secLen = txFrameSecLen(desc, result.macLen, result.snapLen)
  let snapAddr = payload - result.snapLen.uint
  let secAddr = snapAddr - result.secLen.uint
  let macAddr = secAddr - result.macLen.uint
  result.mac = cast[ptr MacQosDataFrameHeaderView](macAddr)
  result.sec = cast[ptr TxSecurityHeaderView](secAddr)
  result.snap =
    if result.snapLen == 0'u8: nil
    else: cast[ptr LlcSnapHeaderView](snapAddr)

proc txFrameWriteSnap(layout: TxFrameBuildLayout; ethertype: uint16) {.inline.} =
  if layout.snap != nil:
    layout.snap.dsap = 0xAA'u8
    layout.snap.ssap = 0xAA'u8
    layout.snap.control = 0x03'u8
    layout.snap.oui = [0'u8, 0'u8, 0'u8]
    layout.snap.ethertype = ethertype

proc macAddrLo32(addrBytes: ptr array[6, uint8]): uint32 {.inline.} =
  cast[ptr uint16](unsafeAddr addrBytes[][0])[].uint32 or
    (cast[ptr uint16](unsafeAddr addrBytes[][2])[].uint32 shl 16)

proc macAddrHi16(addrBytes: ptr array[6, uint8]): uint32 {.inline.} =
  cast[ptr uint16](unsafeAddr addrBytes[][4])[].uint32

proc macAddrWord0(addrBytes: ptr array[6, uint8]): uint32 {.inline.} =
  addrBytes[][0].uint32 or
    (addrBytes[][1].uint32 shl 8) or
    (addrBytes[][2].uint32 shl 16) or
    (addrBytes[][3].uint32 shl 24)

proc snapTraceLo(layout: TxFrameBuildLayout): uint32 {.inline.} =
  if layout.snap == nil:
    0'u32
  else:
    layout.snap.dsap.uint32 or
      (layout.snap.ssap.uint32 shl 8) or
      (layout.snap.control.uint32 shl 16) or
      (layout.snap.oui[0].uint32 shl 24)

proc snapTraceHi(layout: TxFrameBuildLayout): uint32 {.inline.} =
  if layout.snap == nil:
    0'u32
  else:
    layout.snap.oui[1].uint32 or
      (layout.snap.oui[2].uint32 shl 8) or
      (layout.snap.ethertype.uint32 shl 16)

template apmStartInfoView(connInfo: pointer): ptr ApmStartInfoView =
  cast[ptr ApmStartInfoView](connInfo)

template apmStartReqView(param: pointer): ptr ApmStartReqView =
  cast[ptr ApmStartReqView](param)

template apmStopReqView(param: pointer): ptr ApmStopReqPayload =
  cast[ptr ApmStopReqPayload](param)

template apmConfMaxStaReqView(param: pointer): ptr ApmConfMaxStaReqPayload =
  cast[ptr ApmConfMaxStaReqPayload](param)

template apmProbeReqView(param: pointer): ptr ApmProbeReqView =
  cast[ptr ApmProbeReqView](param)

template machwKeyWriteParamView(param: pointer): ptr MachwKeyWriteParamView =
  cast[ptr MachwKeyWriteParamView](param)

template machwKeyWriteKeyTailPtr(req: ptr MachwKeyWriteParamView): pointer =
  cast[pointer](addr req.reserved24[0])

template supplicantTkipKeyData(req: ptr SupplicantKeyParamView): ptr SupplicantTkipKeyDataView =
  cast[ptr SupplicantTkipKeyDataView](addr req.keyData[0])

template cfgApiElementEntryAt(entry: pointer): ptr CfgApiElementEntryView =
  cast[ptr CfgApiElementEntryView](entry)

template vifMgmtAddKeyParamView(param: pointer): ptr VifMgmtAddKeyParamView =
  cast[ptr VifMgmtAddKeyParamView](param)

template vifMgmtAddKeyTkipMaterialPtr(req: ptr VifMgmtAddKeyParamView): pointer =
  cast[pointer](addr req.tkipKeyMaterial[0])

proc le32(bytes: ptr array[4, uint8]): uint32 {.inline.} =
  bytes[][0].uint32 or
    (bytes[][1].uint32 shl 8) or
    (bytes[][2].uint32 shl 16) or
    (bytes[][3].uint32 shl 24)

template scanStartReqView(param: pointer): ptr ScanStartReqPayload =
  cast[ptr ScanStartReqPayload](param)

template activeScanReq(): ptr ScanStartReqPayload =
  scanStartReqView(scan_env.paramPtr)

template scanuStartReqView(param: pointer): ptr ScanuStartReqPayload =
  cast[ptr ScanuStartReqPayload](param)

template activeScanuReq(): ptr ScanuStartReqPayload =
  scanuStartReqView(scanu_env.paramPtr)

template scanSsidSlot(req: typed, idx: int): ptr ScanSsidSlotView =
  cast[ptr ScanSsidSlotView](
    cast[uint](addr req.ssidFilter[0]) +
    idx.uint * ScanSsidSlotViewSize.uint)

template lengthPrefixedSsidView(ssid: pointer): ptr ScanSsidSlotView =
  cast[ptr ScanSsidSlotView](ssid)

template scanuFilterSsidSlot(): ptr ScanSsidSlotView =
  cast[ptr ScanSsidSlotView](addr scanu_env.filterSsidLen)

template cacheScanuFilterSsid*(req: ptr ScanuStartReqPayload) =
  scanuFilterSsidSlot()[] = scanSsidSlot(req, 0)[]

template statusCfmView(param: pointer): ptr StatusCfmPayload =
  cast[ptr StatusCfmPayload](param)

template mmStartReqView(param: pointer): ptr MmStartReqPayload =
  cast[ptr MmStartReqPayload](param)

template mmSetIdleReqView(param: pointer): ptr MmSetIdleReqPayload =
  cast[ptr MmSetIdleReqPayload](param)

template mmStaAddReqView(param: pointer): ptr MmStaAddReqPayload =
  cast[ptr MmStaAddReqPayload](param)

template mmStaDelReqView(param: pointer): ptr MmStaDelReqPayload =
  cast[ptr MmStaDelReqPayload](param)

template meAddBaReqParamView(param: pointer): ptr MeAddBaReqParamView =
  cast[ptr MeAddBaReqParamView](param)

template addBaReqActionBodyAt(param: pointer): ptr AddBaReqActionBodyView =
  cast[ptr AddBaReqActionBodyView](param)

template addBaRspActionBodyAt(param: pointer): ptr AddBaRspActionBodyView =
  cast[ptr AddBaRspActionBodyView](param)

template delBaActionBodyAt(param: pointer): ptr DelBaActionBodyView =
  cast[ptr DelBaActionBodyView](param)

template delBaInfoView(param: pointer): ptr DelBaInfoView =
  cast[ptr DelBaInfoView](param)

template smAuthFrameView(param: pointer): ptr SmAuthFrameView =
  cast[ptr SmAuthFrameView](param)

template smConnectIndPayloadAt(param: pointer): ptr SmConnectIndPayload =
  cast[ptr SmConnectIndPayload](param)

template smAuthSaeBodyPtr(frame: ptr SmAuthFrameView): pointer =
  cast[pointer](addr frame.saeBodyFirst)

template smAuthSharedChallengePtr(frame: ptr SmAuthFrameView): pointer =
  cast[pointer](addr frame.sharedChallengeFirst)

template smAssocRspFrameView(param: pointer): ptr SmAssocRspFrameView =
  cast[ptr SmAssocRspFrameView](param)

template smAssocRspBodyPtr(frame: ptr SmAssocRspFrameView): pointer =
  cast[pointer](addr frame.capabilityInfo)

template smAssocRspIePtr(frame: ptr SmAssocRspFrameView): pointer =
  cast[pointer](addr frame.iesFirst)

template smDeauthFrameView(param: pointer): ptr SmDeauthFrameView =
  cast[ptr SmDeauthFrameView](param)

template mfpMgmtFramePolicyView(param: pointer): ptr MfpMgmtFramePolicyView =
  cast[ptr MfpMgmtFramePolicyView](param)

template rxuMgtDispatchView(param: pointer): ptr RxuMgtDispatchView =
  cast[ptr RxuMgtDispatchView](param)

template smSaQueryFrameView(param: pointer): ptr SmSaQueryFrameView =
  cast[ptr SmSaQueryFrameView](param)

template apmStaAddCfmParamView(param: pointer): ptr ApmStaAddCfmParamView =
  cast[ptr ApmStaAddCfmParamView](param)

template apmStaDelReqView(param: pointer): ptr ApmStaDelReqPayload =
  cast[ptr ApmStaDelReqPayload](param)

template mmSetPsModeReqView(param: pointer): ptr MmSetPsModeReqPayload =
  cast[ptr MmSetPsModeReqPayload](param)

template mmConnectionLossIndView(param: pointer): ptr MmConnectionLossIndPayload =
  cast[ptr MmConnectionLossIndPayload](param)

template mmRemainOnChannelReqView(param: pointer): ptr MmRemainOnChannelReqPayload =
  cast[ptr MmRemainOnChannelReqPayload](param)

template smVifIdxReqView(param: pointer): ptr SmVifIdxReqPayload =
  cast[ptr SmVifIdxReqPayload](param)

template smReqVifIdxOrZero(param: pointer): uint8 =
  if param != nil: smVifIdxReqView(param).vifIdx else: 0'u8

template smDisconnectReasonView(param: pointer): ptr SmDisconnectReasonPayload =
  cast[ptr SmDisconnectReasonPayload](param)

template smDisconnectReasonOrDefault(param: pointer): uint16 =
  if param != nil: smDisconnectReasonView(param).reason else: 3'u16

template mmMonitorReqView(param: pointer): ptr MmMonitorReqPayload =
  cast[ptr MmMonitorReqPayload](param)

template meConfigReqView(param: pointer): ptr MeConfigReqPayload =
  cast[ptr MeConfigReqPayload](param)

template meStaAddReqView(param: pointer): ptr MeStaAddReqPayload =
  cast[ptr MeStaAddReqPayload](param)

template meStaAddReqCapBlock(req: ptr MeStaAddReqPayload): pointer =
  cast[pointer](addr req.capBlockHead[0])

template meRcSetRateReqView(param: pointer): ptr MeRcSetRateReqPayload =
  cast[ptr MeRcSetRateReqPayload](param)

template meTrafficIndReqView(param: pointer): ptr MeTrafficIndReqPayload =
  cast[ptr MeTrafficIndReqPayload](param)

template rcRetryChainParamView(param: pointer): ptr RcRetryChainParamPayload =
  cast[ptr RcRetryChainParamPayload](param)

template rcRetryChainParamOrZero(param: pointer): uint32 =
  if param != nil: rcRetryChainParamView(param).throughput else: 0'u32

template apmRxMgmtPrefix(param: pointer): ptr ApmRxMgmtPrefixView =
  cast[ptr ApmRxMgmtPrefixView](param)

template apmAssocHtCapInfo(msg: ptr ApmAssocStaAddIndPayload): ptr uint16 =
  addr cast[ptr ApmAssocStaAddIndHtOverlay](msg).capInfo

template apmAssocHtExtendedCap(msg: ptr ApmAssocStaAddIndPayload): ptr uint16 =
  addr cast[ptr ApmAssocStaAddIndHtOverlay](msg).extendedCap

template apmAssocTxBfCap(msg: ptr ApmAssocStaAddIndPayload): ptr uint32 =
  addr cast[ptr ApmAssocStaAddIndHtOverlay](msg).txBfCap

template apmAssocAselCap(msg: ptr ApmAssocStaAddIndPayload): ptr uint8 =
  addr cast[ptr ApmAssocStaAddIndHtOverlay](msg).aselCap

template psUapsdTimer(): pointer =
  cast[pointer](addr psEnvView().nullRetryLimit)

template psTxNullTimer(): pointer =
  cast[pointer](addr psEnvView().txNullTimerWord)

template mmEnvClearKeepAliveTimestampByte1() =
  let mm = mmEnvView()
  mm.keepAliveTimestamp = mm.keepAliveTimestamp and not 0x0000FF00'u32

template mmBcnTemplateByte(idx: static[int]): untyped =
  cast[ptr UncheckedArray[uint8]](addr bcnEnvView().templatePtr)[idx]

template nextTxSeqNumber(): uint16 =
  block:
    let txCtrl = txControlEnv()
    txCtrl.seqCounter = (txCtrl.seqCounter + 1) and 0x0FFF'u16
    txCtrl.seqCounter

template nextTxSeqCtrl(): uint16 =
  nextTxSeqNumber() shl 4

template chanCtxtAt(p: uint): ptr ChanCtxtView =
  cast[ptr ChanCtxtView](p)

template chanCtxtAt(p: pointer): ptr ChanCtxtView =
  cast[ptr ChanCtxtView](p)

template chanCtxtForIdx(idx: uint8): ptr ChanCtxtView =
  chanCtxtAt(cast[uint](addr chan_ctxt_pool[0]) +
    idx.uint * sizeof(ChanCtxtView).uint)

template chanScanPoolOverlay(): ptr ChanScanPoolOverlay =
  cast[ptr ChanScanPoolOverlay](cast[uint](addr chan_ctxt_pool[0]) + 0x58'u)

template chanRocOverlay(): ptr ChanRocOverlay =
  cast[ptr ChanRocOverlay](cast[uint](addr chan_env[0]) + 126'u)

template chanCtxtHdr(ctxt: ptr ChanCtxtView): ptr CoListHdr =
  cast[ptr CoListHdr](ctxt)

template chanTbttNodeAt(p: pointer): ptr ChanTbttNodeView =
  cast[ptr ChanTbttNodeView](p)

template chanTbttHdr(node: ptr ChanTbttNodeView): ptr CoListHdr =
  cast[ptr CoListHdr](node)

template vifChannelAt(p: pointer): ptr VifChannelView =
  cast[ptr VifChannelView](p)

template vifChannelAt(p: uint): ptr VifChannelView =
  cast[ptr VifChannelView](p)

template vifEntryAddr(idx: uint8): uint =
  cast[uint](addr vif_info_tab[0]) + idx.uint * VIF_ENTRY_SIZE.uint

template vifChannelForIdx(idx: uint8): ptr VifChannelView =
  vifChannelAt(vifEntryAddr(idx))

template vifChannelTypeByte(vif: ptr VifChannelView): ptr uint8 =
  cast[ptr uint8](addr vif.flags)

template vifPostponedStaList(vif: ptr VifChannelView): ptr CoList =
  cast[ptr CoList](addr vif.postponedStaHead)

template vifEdcaPsGate(vif: ptr VifChannelView): int8 =
  cast[int8](vif.wmmQosInfo)

template vifWpaCipher(vif: ptr VifChannelView): uint8 =
  vif.wmmQosInfo

template vifSecurity(vif: ptr VifChannelView): ptr VifSecurityOverlay =
  cast[ptr VifSecurityOverlay](addr vif.edcaParams[32])

template vifSecurityAt(p: uint): ptr VifSecurityOverlay =
  vifSecurity(vifChannelAt(p))

template vifMachwKeyIndexes(vif: ptr VifChannelView): ptr VifMachwKeyIndexOverlay =
  cast[ptr VifMachwKeyIndexOverlay](vif)

template vifAssocInfo(info: pointer): ptr VifAssocInfoOverlay =
  cast[ptr VifAssocInfoOverlay](info)

template vifHtCapabilities(vif: ptr VifChannelView): ptr VifHtCapabilitiesOverlay =
  cast[ptr VifHtCapabilitiesOverlay](addr vif.reserved344[4])

template vifHtCapabilitiesAt(p: uint): ptr VifHtCapabilitiesOverlay =
  vifHtCapabilities(vifChannelAt(p))

template vifHtOperation(vif: ptr VifChannelView): ptr VifHtOperationOverlay =
  cast[ptr VifHtOperationOverlay](addr vif.edcaParams[20])

template vifApConfig(vif: ptr VifChannelView): ptr VifApConfigOverlay =
  cast[ptr VifApConfigOverlay](addr vif.edcaParams[0])

template vifApConfigAt(p: uint): ptr VifApConfigOverlay =
  vifApConfig(vifChannelAt(p))

template vifApEdcaWord(apCfg: ptr VifApConfigOverlay, idx: int): ptr uint32 =
  cast[ptr uint32](addr apCfg.edcaParams[idx * 4])

template vifKeySlotTable(vif: ptr VifChannelView): ptr VifKeySlotTableOverlay =
  cast[ptr VifKeySlotTableOverlay](vif)

template vifKeySlot(vif: ptr VifChannelView, slot: uint): ptr VifKeySlotView =
  addr vifKeySlotTable(vif).slots[slot]

template vifKeySlotAt(vifEntry: uint, slot: uint): ptr VifKeySlotView =
  vifKeySlot(vifChannelAt(vifEntry), slot)

template vifKeySlotPtr(vif: ptr VifChannelView, slot: uint): uint32 =
  cast[uint32](cast[uint](vifKeySlot(vif, slot)))

template vifRxProtectedKeySlot(vif: ptr VifChannelView, slot: uint): ptr VifKeySlotView =
  addr cast[ptr VifRxProtectedKeyTableOverlay](vif).slots[slot]

template tkipMicKeyArea(key: ptr VifKeySlotView;
                        micKeyOff: uint): ptr TkipMicKeyAreaView =
  cast[ptr TkipMicKeyAreaView](cast[uint](key) + micKeyOff - 24)

template replayCounterStateView(param: pointer): ptr ReplayCounterStateView =
  cast[ptr ReplayCounterStateView](param)

template vifKeyPointersAt(vifEntry: uint): ptr VifKeyPointersView =
  cast[ptr VifKeyPointersView](vifEntry + 1488'u)

template vifKeyPointers(vif: ptr VifChannelView): ptr VifKeyPointersView =
  vifKeyPointersAt(cast[uint](vif))

template txSecurityKeyListAt(p: pointer): ptr TxSecurityKeyListView =
  cast[ptr TxSecurityKeyListView](p)

template secMacRxIndAt(p: pointer): ptr SecMacRxIndView =
  cast[ptr SecMacRxIndView](p)

template txPolicyAt(p: pointer): ptr TxPolicyView =
  cast[ptr TxPolicyView](p)

template michaelMicContextAt(p: pointer): ptr MichaelMicContextView =
  cast[ptr MichaelMicContextView](p)

template apmTxDescPsAt(p: pointer): ptr ApmTxDescPsView =
  cast[ptr ApmTxDescPsView](p)

template hostTxDescAt(p: pointer): ptr HostTxDescView =
  cast[ptr HostTxDescView](p)

template txlFrameDescSlotAt(idx: uint32): ptr TxlFrameDescSlotView =
  addr cast[ptr UncheckedArray[TxlFrameDescSlotView]](
    addr txl_frame_desc_storage[0])[idx]

template txlFrameDescAt(idx: uint32): ptr HostTxDescView =
  addr txlFrameDescSlotAt(idx).desc

template hostTxPnScratch(desc: ptr HostTxDescView): ptr TxPnScratchView =
  cast[ptr TxPnScratchView](addr desc.pnScratch[0])

template hostTxHwDescAt(p: pointer): ptr HostTxHwDescView =
  cast[ptr HostTxHwDescView](p)

template txlFrameHwDescSlotAt(idx: uint32): ptr TxlFrameHwDescSlotView =
  addr cast[ptr UncheckedArray[TxlFrameHwDescSlotView]](
    addr txl_frame_hwdesc_pool[0])[idx]

template txlFrameHwDescAt(idx: uint32): ptr HostTxHwDescView =
  addr txlFrameHwDescSlotAt(idx).desc

template txlFrameHwCfmAt(idx: uint32): ptr TxlFrameHwCfmSlotView =
  addr cast[ptr UncheckedArray[TxlFrameHwCfmSlotView]](
    addr txl_frame_hwdesc_cfms[0])[idx]

template hostTxLinkDescAt(p: pointer): ptr HostTxLinkDescView =
  cast[ptr HostTxLinkDescView](p)

template txlFrameLinkSlotAt(idx: uint32): ptr TxlFrameLinkSlotView =
  addr cast[ptr UncheckedArray[TxlFrameLinkSlotView]](
    addr txl_frame_pool[0])[idx]

template txlFrameLinkDescAt(idx: uint32): ptr HostTxLinkDescView =
  cast[ptr HostTxLinkDescView](addr txlFrameLinkSlotAt(idx).storage[0])

template hostTxBufferedLinkAt(p: pointer): ptr HostTxBufferedLinkView =
  cast[ptr HostTxBufferedLinkView](p)

template hostTxInternalLinkNodeAt(p: pointer): ptr HostTxInternalLinkNodeView =
  cast[ptr HostTxInternalLinkNodeView](p)

template hostTxInlineBufferedLink(desc: ptr HostTxDescView): ptr HostTxBufferedLinkView =
  cast[ptr HostTxBufferedLinkView](addr desc.callback)

template hostTxAuxWords(desc: ptr HostTxDescView): ptr HostTxAuxWordsView =
  cast[ptr HostTxAuxWordsView](addr desc.callback)

template hostTxRateTemplate(link: ptr HostTxLinkDescView): ptr HostTxRateTemplateView =
  cast[ptr HostTxRateTemplateView](addr link.rateTemplate[0])

template hostTxRateTemplate(link: ptr HostTxBufferedLinkView): ptr HostTxRateTemplateView =
  cast[ptr HostTxRateTemplateView](addr link.rateTemplate[0])

template hostTxRateTemplateAt(p: pointer): ptr HostTxRateTemplateView =
  cast[ptr HostTxRateTemplateView](p)

template hostTxHeadThd(hw: ptr HostTxHwDescView): ptr HostTxThdEntryView =
  cast[ptr HostTxThdEntryView](hw.txConfirmDescPtr.uint)

template hostTxThdAt(p: pointer): ptr HostTxThdEntryView =
  cast[ptr HostTxThdEntryView](p)

template hostTxThdConfirmAt(p: ptr HostTxThdEntryView): ptr HostTxThdConfirmView =
  cast[ptr HostTxThdConfirmView](p)

template txDumpRateDescAt(p: pointer): ptr TxDumpRateDescView =
  cast[ptr TxDumpRateDescView](p)

template txDumpBufferDescAt(p: pointer): ptr TxDumpBufferDescView =
  cast[ptr TxDumpBufferDescView](p)

template txBufferControlAt(p: pointer): ptr TxBufferControlView =
  cast[ptr TxBufferControlView](p)

template txlFramePayloadSlotAt(idx: uint32): ptr TxlFramePayloadSlotView =
  addr cast[ptr UncheckedArray[TxlFramePayloadSlotView]](
    addr txl_frame_buf_ctrl[0])[idx]

template txlFramePayloadDescAt(idx: uint32): ptr TxBufferControlView =
  addr txlFramePayloadSlotAt(idx).desc

template txBufferControl24G(): ptr TxBufferControlView =
  cast[ptr TxBufferControlView](addr txl_buffer_control_24G[0])

template txBufferControlDescAt(idx: int): ptr TxBufferControlView =
  addr cast[ptr UncheckedArray[TxBufferControlView]](addr txl_buffer_control_desc[0])[idx]

template txBufferControlBcmcDescAt(idx: int): ptr TxBufferControlView =
  addr cast[ptr UncheckedArray[TxBufferControlView]](addr txl_buffer_control_desc_bcmc[0])[idx]

template txlBufferEnvView(): ptr TxlBufferEnvView =
  cast[ptr TxlBufferEnvView](addr txl_buffer_env[0])

template ipcSharedEnvView(): ptr IpcSharedEnvView =
  cast[ptr IpcSharedEnvView](addr ipcSharedEnv[0])

template ipcEmbEnvView(): ptr IpcEmbEnvView =
  cast[ptr IpcEmbEnvView](addr ipcEmbEnvStruct[0])

template ipcHostTxWrapperAt(p: pointer): ptr IpcHostTxWrapperView =
  cast[ptr IpcHostTxWrapperView](p)

template ipcHostTxWrapperFromDesc(desc: ptr HostTxDescView): ptr IpcHostTxWrapperView =
  cast[ptr IpcHostTxWrapperView](cast[uint](desc) - offsetof(IpcHostTxWrapperView, txDesc).uint)

proc ipcHostTxHead(env: ptr IpcEmbEnvView): ptr IpcHostTxWrapperView {.inline.} =
  if env.hostTxList == nil or env.hostTxList.first == nil:
    return nil
  ipcHostTxWrapperAt(cast[pointer](env.hostTxList.first))

template ipcTxAcDescAt(ac: uint32): ptr IpcTxAcDescView =
  cast[ptr IpcTxAcDescView]((IPC_TX_AC_DESC_BASE + ac * IPC_TX_AC_DESC_STRIDE).uint)

proc ipcTxAcDescClear(ac: uint32) {.inline.} =
  let desc = ipcTxAcDescAt(ac)
  volatileStore(addr desc.descriptor, 0'u32)
  volatileStore(addr desc.busy, 0'u8)
  volatileStore(addr desc.sequence, 0'u16)

template ipcTxHwDescWordTable(): ptr IpcTxHwDescWordTableView =
  cast[ptr IpcTxHwDescWordTableView](IPC_TX_AC_DESC_BASE.uint)

proc ipcTxHwDescWordAddrHalfword(ac: uint32): uint16 {.inline.} =
  cast[uint](addr ipcTxHwDescWordTable().descriptorWords[ac.int]).uint16

template hostTxLinkMacHdrAddr(link: ptr HostTxLinkDescView): uint =
  cast[uint](addr link.macHeader[0])

template hostTxLinkMacHdrPtr(link: ptr HostTxLinkDescView; offset: uint): pointer =
  cast[pointer](addr link.macHeader[offset.int])

template hostTxLinkMacHdrPtr(link: ptr HostTxBufferedLinkView; offset: uint): pointer =
  cast[pointer](addr link.macHeader[offset.int])

template hostTxMacHdrAddr(desc: ptr HostTxDescView): uint =
  hostTxLinkMacHdrAddr(hostTxLinkDescAt(desc.bufDesc))

template hostTxDataHeader(desc: ptr HostTxDescView): ptr MacDataFrameHeaderView =
  cast[ptr MacDataFrameHeaderView](addr hostTxLinkDescAt(desc.bufDesc).macHeader[0])

template hostTxQosDataHeader(desc: ptr HostTxDescView): ptr MacQosDataFrameHeaderView =
  cast[ptr MacQosDataFrameHeaderView](addr hostTxLinkDescAt(desc.bufDesc).macHeader[0])

template hostTxCtsHeader(desc: ptr HostTxDescView): ptr MacCtsFrameHeaderView =
  cast[ptr MacCtsFrameHeaderView](addr hostTxLinkDescAt(desc.bufDesc).macHeader[0])

template hostTxPsPollHeader(desc: ptr HostTxDescView): ptr PsPollFrameHeaderView =
  cast[ptr PsPollFrameHeaderView](addr hostTxLinkDescAt(desc.bufDesc).macHeader[0])

template saQueryActionBodyAt(p: pointer): ptr SaQueryActionBodyView =
  cast[ptr SaQueryActionBodyView](p)

template hostTxConfirmLinkWord(desc: ptr HostTxDescView): ptr uint32 =
  addr ipcHostTxWrapperFromDesc(desc).active

template txBackupQueueHeadPtr(queueIdx: uint32): ptr pointer =
  addr txlBufferEnvView().backupQueues[queueIdx].first

template txBackupQueueTailPtr(queueIdx: uint32): ptr pointer =
  addr txlBufferEnvView().backupQueues[queueIdx].last

template staInfoAt(p: pointer): ptr StaInfoView =
  cast[ptr StaInfoView](p)

template staInfoAt(p: uint): ptr StaInfoView =
  cast[ptr StaInfoView](p)

template staInfoForIdx(idx: uint8): ptr StaInfoView =
  staInfoAt(cast[uint](addr sta_info_tab[0]) +
    idx.uint * STA_ENTRY_SIZE.uint)

template staBandwidthOverlay(sta: ptr StaInfoView): ptr StaBandwidthOverlay =
  cast[ptr StaBandwidthOverlay](addr sta.reserved74[2])

template staTxSequence(sta: ptr StaInfoView): ptr StaTxSequenceOverlay =
  cast[ptr StaTxSequenceOverlay](sta)

template rxuQosSeqCacheTable(): ptr RxuQosSeqCacheTableOverlay =
  cast[ptr RxuQosSeqCacheTableOverlay](addr sta_info_tab[0])

template staPowerConstraintOut(sta: ptr StaInfoView): pointer =
  cast[pointer](addr sta.reserved338[10])

template apSelfStaStart(sta: ptr StaInfoView): ptr ApSelfStaStartOverlay =
  cast[ptr ApSelfStaStartOverlay](sta)

template staMgmtRegisterParamView(param: pointer): ptr StaMgmtRegisterParamView =
  cast[ptr StaMgmtRegisterParamView](param)

proc staMacWords(sta: ptr StaInfoView): tuple[lo, hi: uint32] {.inline.} =
  result.lo = sta.macAddr[0].uint32 or
              (sta.macAddr[1].uint32 shl 8) or
              (sta.macAddr[2].uint32 shl 16) or
              (sta.macAddr[3].uint32 shl 24)
  result.hi = sta.macAddr[4].uint32 or
              (sta.macAddr[5].uint32 shl 8)

template blOpsData(): ptr BlOpsDataView =
  cast[ptr BlOpsDataView](addr g_bl_ops_funcs)

proc word24(ops: ptr BlOpsDataView): uint32 {.inline.} =
  ops.beaconTimeoutConfig[0].uint32 or
    (ops.beaconTimeoutConfig[1].uint32 shl 8) or
    (ops.beaconTimeoutConfig[2].uint32 shl 16) or
    (ops.beaconTimeoutConfig[3].uint32 shl 24)

template chanEnvView(): ptr ChanEnvView =
  cast[ptr ChanEnvView](addr chan_env[0])

template chanRssiLastReportTime(): ptr uint32 =
  cast[ptr uint32](cast[uint](addr chan_env[0]) + sizeof(ChanEnvView).uint)

template chanTbttConflictCounter(): ptr uint32 =
  cast[ptr uint32](addr chanEnvView().deferredMsg)

template rxuCntrlEnvView(): ptr RxuCntrlEnvView =
  cast[ptr RxuCntrlEnvView](addr rxu_cntrl_env[0])

template rxlCntrlEnvView(): ptr RxlCntrlEnvView =
  cast[ptr RxlCntrlEnvView](addr rxl_cntrl_env[0])

template rxHwDescEnvView(): ptr RxHwDescEnvView =
  cast[ptr RxHwDescEnvView](addr rx_hwdesc_env[0])

template rxHeaderHwDescAt(idx: int): ptr RxHeaderHwDescView =
  addr cast[ptr UncheckedArray[RxHeaderHwDescView]](addr rx_dma_hdrdesc[0])[idx]

template rxHeaderHwDescView(param: pointer): ptr RxHeaderHwDescView =
  cast[ptr RxHeaderHwDescView](param)

template rxSwTableDescAt(idx: int): ptr RxSwTableDescView =
  addr cast[ptr UncheckedArray[RxSwTableDescView]](addr rx_swdesc_tab[0])[idx]

template rxPayloadHwDescAt(idx: int): ptr RxPayloadHwDescView =
  addr cast[ptr UncheckedArray[RxPayloadHwDescView]](addr rx_payload_desc[0])[idx]

template rxPayloadBufferAt(idx: int): ptr RxPayloadBufferView =
  addr cast[ptr UncheckedArray[RxPayloadBufferView]](addr rx_payload_desc_buffer[0])[idx]

template rxSwDescView(param: pointer): ptr RxSwDescView =
  cast[ptr RxSwDescView](param)

template rxMpduDescView(param: pointer): ptr RxMpduDescView =
  cast[ptr RxMpduDescView](param)

template beaconRxDescView(param: pointer): ptr BeaconRxDescView =
  cast[ptr BeaconRxDescView](param)

template beaconPayloadDescView(param: pointer): ptr BeaconPayloadDescView =
  cast[ptr BeaconPayloadDescView](param)

template beaconFrameFixedView(param: pointer): ptr BeaconFrameFixedView =
  cast[ptr BeaconFrameFixedView](param)

template beaconFrameIeBody(frame: ptr BeaconFrameFixedView): pointer =
  addr frame.body[0]

template probeRspFixedBodyView(param: pointer): ptr ProbeRspFixedBodyView =
  cast[ptr ProbeRspFixedBodyView](param)

template probeRspIeBody(frame: ptr ProbeRspFixedBodyView): pointer =
  addr frame.body[0]

proc ieCursorAfter(p: pointer; n: uint): pointer {.inline.} =
  addr cast[ptr UncheckedArray[uint8]](p)[n]

template htMcsNssPrefixView(param: pointer): ptr HtMcsNssPrefixView =
  cast[ptr HtMcsNssPrefixView](param)

template chanTimerAt(offset: uint): pointer =
  cast[pointer](cast[uint](addr chan_env[0]) + offset)

template chanTbttPrimaryList(): ptr CoList =
  cast[ptr CoList](cast[uint](addr chan_env[0]) + 0x10'u)

template chanTbttReschedList(): ptr CoList =
  cast[ptr CoList](cast[uint](addr chan_env[0]) + 0x18'u)

template chanTbttDeferredSlot(): ptr pointer =
  addr chanEnvView().tbttDeferredSlot

template chanTbttTimer(): pointer =
  chanTimerAt(0x2C'u)

template chanTbttSwitchTimer(): pointer =
  chanTimerAt(48'u)

template chanCtxtOpTimer(): pointer =
  chanTimerAt(76'u)

template chanConnLessDelayTimer(): pointer =
  chanTimerAt(92'u)

proc markInvalid(ctxt: ptr ChanCtxtView) {.inline.} =
  ctxt.invalidMarker = 0xFF'u8
  ctxt.idx = 0xFF'u8

type
  KeEvtEntry* = object
    handler*: pointer       # function pointer
    param*: pointer         # event-specific context

  KeTimerEntry* = object
    next*: ptr KeTimerEntry
    id*: uint16             # task_id in bits [15:10], msg in bits [9:0]
    taskId*: uint8          # target task
    time*: uint32           # absolute expiry in MAC ticks

# Kernel message handler descriptor (8 bytes)
# Used by ke_handler_search: pairs a handler table pointer with its entry count.
type
  KeMsgHandlerEntry* {.packed.} = object
    msgId*: uint32          # lower 16 bits are the KE message id
    handler*: pointer

  KeMsgHandlerDesc* = object
    handlers*: pointer      # offset 0: ptr to MsgHandlerEntry array (8 bytes each)
    numHandlers*: uint16    # offset 4: number of entries in the table
    padding*: uint16        # offset 6

# Kernel task descriptor (16 bytes, indexed by task ID)
# The blob uses state-based dispatch: stateTable[state] gives a KeMsgHandlerDesc
# for that state, and defaultHandler is the fallback descriptor.
type
  KeTaskDesc* = object
    stateTable*: pointer       # offset 0: ptr to array of KeMsgHandlerDesc (one per state)
    defaultHandler*: pointer   # offset 4: ptr to KeMsgHandlerDesc for fallback/default handlers
    statePtr*: ptr uint16      # offset 8: ptr to this task's current state variable
    reserved*: uint16          # offset 12: reserved
    stateCount*: uint16        # offset 14: number of valid states (asserted > 0)

static:
  doAssert offsetof(KeMsgHandlerEntry, msgId) == 0
  doAssert offsetof(KeMsgHandlerEntry, handler) == 4
  doAssert sizeof(KeMsgHandlerEntry) == 8
  doAssert offsetof(KeMsgHandlerDesc, handlers) == 0
  doAssert offsetof(KeMsgHandlerDesc, numHandlers) == 4
  doAssert sizeof(KeMsgHandlerDesc) == 8
  doAssert offsetof(KeTaskDesc, stateTable) == 0
  doAssert offsetof(KeTaskDesc, defaultHandler) == 4
  doAssert offsetof(KeTaskDesc, statePtr) == 8
  doAssert offsetof(KeTaskDesc, stateCount) == 14
  doAssert sizeof(KeTaskDesc) == 16

template keMsgHandlerEntryAt(table: pointer, idx: uint16): ptr KeMsgHandlerEntry =
  addr cast[ptr UncheckedArray[KeMsgHandlerEntry]](table)[idx]

template keMsgHandlerDescAt(table: pointer, state: uint16): ptr KeMsgHandlerDesc =
  addr cast[ptr UncheckedArray[KeMsgHandlerDesc]](table)[state]

{.pragma: wifiCtrl, codegenDecl: "$# $# __attribute__((section(\".ram_wifi_ctrl\")))".}
{.pragma: wifiCtrlExport, exportc, codegenDecl: "$# $# __attribute__((section(\".ram_wifi_ctrl\")))".}
{.pragma: weakExport, exportc, codegenDecl: "$# __attribute__((weak)) $#$#".}
{.pragma: wifiRxDmaHd, codegenDecl: "$# $# __attribute__((section(\".wifibss.rx_dma.0_hd\"), aligned(16), used))".}
{.pragma: wifiRxDmaPd, codegenDecl: "$# $# __attribute__((section(\".wifibss.rx_dma.1_pd\"), aligned(16), used))".}
{.pragma: wifiRxDmaSw, codegenDecl: "$# $# __attribute__((section(\".wifibss.rx_dma.2_sw\"), aligned(16), used))".}
{.pragma: wifiRxDmaBuf, codegenDecl: "$# $# __attribute__((section(\".wifibss.rx_dma.3_buf\"), aligned(16), used))".}

# TX DMA descriptor (from disassembly analysis of txl_buffer_init)
type
  TxHwDesc* = object
    status*: uint32         # status/control word (badcab1e = unused)
    bufAddr*: uint32        # physical buffer address (shifted <<14)
    bufMask*: uint32        # buffer address mask
    reserved0*: uint32
    controlInfo*: uint32    # ffff0704-pattern control
    reserved1*: uint32
    reserved2*: uint32
    reserved3*: uint32
    reserved4*: uint32
    rngVal0*: uint32        # random from MACHW RNG
    rngVal1*: uint32
    rngVal2*: uint32
    rngVal3*: uint32
    edcaParam0*: uint32     # EDCA: 0x2200
    edcaParam1*: uint32     # EDCA: 0x3f0000

  TxBufferDesc* = object
    descs*: array[TX_BUFFER_POOL_SIZE, TxHwDesc]
    internDescs*: array[2, TxHwDesc]
    allocIdx*: uint32
    freeIdx*: uint32

# RX DMA descriptor
type
  RxHwDesc* = object
    next*: ptr RxHwDesc     # linked list next
    bufPtr*: ptr uint8      # buffer pointer
    bufLen*: uint32         # buffer length
    status*: uint16         # bit 0 = DMA owned
    padding*: uint16

  RxSwDesc* = object
    hwDesc*: ptr RxHwDesc
    hostBuf*: pointer
    payloadLen*: uint32
    lastDesc*: ptr RxHwDesc
    curDesc*: ptr RxHwDesc
    dmaCount*: uint8

const SCANU_MAX_RESULT_ENTRIES* = 6

type
  ScanuResultEntry* = object
    bssid*: array[6, uint8]
    band*: uint16
    chanPtr*: pointer
    beaconPeriod*: uint16
    capInfo*: uint16
    valid*: uint8
    rssi*: int8
    noiseFloor1*: int8
    noiseFloor2*: int8
    securityType*: uint16
    securityAuth*: uint8
    pad23*: uint8
    rawMsgPtr*: pointer

  ScanuCachedSsid* = object
    valid*: uint8
    length*: uint8
    data*: array[32, uint8]

  ScanuEnvObj* = object
    paramPtr*: pointer
    entries*: array[SCANU_MAX_RESULT_ENTRIES, ScanuResultEntry]
    pendingRawMsg*: pointer
    requester*: uint8
    reserved0*: uint8
    resultCount*: uint16
    bssidFilterEnabled*: uint8
    scanBand*: uint8
    filterBssid*: array[6, uint8]
    filterSsidLen*: uint8
    filterSsid*: array[32, uint8]
    reserved1*: uint8
    resultState*: uint8
    reserved2*: uint8
    probeIeCopyDst*: pointer
    directedFound*: uint8
    joinRetryCount*: uint8
    reserved3*: uint16
    extraIePtr*: pointer
    extraIeLen*: uint16
    reserved4*: uint16

  ScanuChannelConfigOverlay {.packed.} = object
    entries*: array[14, ScanChannelEntry]
    count*: uint8

  ScanEnvObj* {.packed.} = object
    paramPtr*: pointer
    chanInfoPtr*: pointer
    requester*: uint8
    channelIndex*: uint8
    abortFlag*: uint8
    reserved*: uint8
    activeDuration*: uint32
    passiveDuration*: uint32
    joinActiveDuration*: uint32

  ScanProbeReqIeObj* {.packed.} = object
    hdr*: array[16, uint8]
    magic*: uint32
    reserved0*: uint32
    ieDataPtr*: pointer
    endOffset*: uint32
    writeOffset*: uint32
    ieData*: array[200, uint8]

  ScanuAddIeObj* {.packed.} = object
    hdr*: array[16, uint8]
    ieData*: array[200, uint8]

  ChanScanReqPayload {.packed.} = object
    reqType*: uint8
    vifIdx*: uint8
    reserved0*: uint16
    duration*: uint32
    band*: uint8
    reserved1*: uint8
    prim20Freq*: uint16
    center1Freq*: uint16
    center2Freq*: uint16
    txPower*: int8
    reserved2*: array[15, uint8]

  ChanScanAbortPayload {.packed.} = object
    reqType*: uint8
    reserved*: array[19, uint8]

  ProbeReqFixedFrame {.packed.} = object
    frameControl*: uint16
    duration*: uint16
    addr1*: array[6, uint8]
    addr2*: array[6, uint8]
    addr3*: array[6, uint8]
    seqCtrl*: uint16
    ssidIeId*: uint8
    ssidLen*: uint8

  ProbeReqFrameView {.packed.} = object
    fixed*: ProbeReqFixedFrame
    ssidData*: UncheckedArray[uint8]

  RxuMgtIndView {.packed.} = object
    frameLen*: uint16
    reserved0*: uint16
    freq*: uint16
    band*: uint8
    reserved1*: array[17, uint8]
    rssi*: int8
    noiseFloor2*: int8
    noiseFloor1*: int8
    reserved2*: array[21, uint8]
    bssid*: array[6, uint8]
    reserved3*: array[10, uint8]
    beaconPeriod*: uint16
    capInfo*: uint16
    ieData*: UncheckedArray[uint8]

  PhyRxVectorView {.packed.} = object
    word0*: uint32
    word1*: uint32
    reserved8*: array[11, uint8]
    rssiLo*: uint8
    rssiHi*: uint8
    reserved21*: array[19, uint8]
    durationFormat*: uint8
    reserved41*: array[3, uint8]
    durationLength*: uint8

  MacAddrView {.packed.} = object
    bytes*: array[6, uint8]

  MacIeView {.packed.} = object
    id*: uint8
    len*: uint8

  MmIeView {.packed.} = object
    ie*: MacIeView
    keyId*: uint16
    ipn*: array[6, uint8]
    mic*: array[8, uint8]

  RateSetView {.packed.} = object
    count*: uint8
    rates*: UncheckedArray[uint8]

  MacIeDataView {.packed.} = object
    ie*: MacIeView
    data*: UncheckedArray[uint8]

  TimeoutIntervalIeView {.packed.} = object
    ie*: MacIeView
    intervalType*: uint8
    intervalValue*: array[4, uint8]

  SsidIeView {.packed.} = object
    ie*: MacIeView
    data*: UncheckedArray[uint8]

  DsParamSetIeView {.packed.} = object
    ie*: MacIeView
    currentChannel*: uint8
    next*: UncheckedArray[uint8]

  OneByteMacIeView {.packed.} = object
    ie*: MacIeView
    value*: uint8
    next*: UncheckedArray[uint8]

  BssMaxIdlePeriodIeView {.packed.} = object
    ie*: MacIeView
    idlePeriod*: uint16
    idleOptions*: uint8
    next*: UncheckedArray[uint8]

  WmmAcParamRecord {.packed.} = object
    raw*: array[4, uint8]

  WmmInfoIeView {.packed.} = object
    ie*: MacIeView
    oui*: array[3, uint8]
    ouiType*: uint8
    ouiSubtype*: uint8
    version*: uint8
    qosInfo*: uint8
    next*: UncheckedArray[uint8]

  WmmParameterIeView {.packed.} = object
    ie*: MacIeView
    oui*: array[3, uint8]
    ouiType*: uint8
    ouiSubtype*: uint8
    version*: uint8
    qosInfo*: uint8
    reserved9*: uint8
    ac*: array[4, WmmAcParamRecord]
    next*: UncheckedArray[uint8]

  HtCapIeView {.packed.} = object
    ie*: MacIeView
    capInfo*: uint16
    ampduParams*: uint8
    mcsSet*: array[16, uint8]
    extCap*: uint16
    txBfCapsLo*: uint16
    txBfCapsHi*: uint16
    aselCap*: uint8
    next*: UncheckedArray[uint8]

  HtOperIeView {.packed.} = object
    ie*: MacIeView
    primaryChannel*: uint8
    secondaryOffset*: uint8
    htProtection*: uint8
    operationMode*: array[3, uint8]
    basicMcsSet*: array[16, uint8]
    next*: UncheckedArray[uint8]

  RsnSuiteView {.packed.} = object
    oui*: array[3, uint8]
    suiteType*: uint8

  RsnCcmpPskIeView {.packed.} = object
    ie*: MacIeView
    version*: uint16
    groupCipher*: RsnSuiteView
    pairwiseCount*: uint16
    pairwiseCipher*: RsnSuiteView
    akmCount*: uint16
    akmSuite*: RsnSuiteView
    capabilities*: uint16
    next*: UncheckedArray[uint8]

  RsnTkipCcmpIeView {.packed.} = object
    ie*: MacIeView
    version*: uint16
    groupCipher*: RsnSuiteView
    pairwiseCount*: uint16
    pairwiseCipher*: array[2, RsnSuiteView]
    akmCount*: uint16
    akmSuite*: RsnSuiteView
    capabilities*: uint16
    next*: UncheckedArray[uint8]

  WpaVendorIeView {.packed.} = object
    ie*: MacIeView
    vendorType*: array[4, uint8]
    version*: uint16
    groupCipher*: RsnSuiteView
    pairwiseCount*: uint16
    pairwiseCipher*: array[2, RsnSuiteView]
    akmCount*: uint16
    akmSuite*: RsnSuiteView
    next*: UncheckedArray[uint8]

  WpaPskVendorIeView {.packed.} = object
    ie*: MacIeView
    vendorType*: array[4, uint8]
    version*: uint16
    groupCipher*: RsnSuiteView
    pairwiseCount*: uint16
    pairwiseCipher*: RsnSuiteView
    akmCount*: uint16
    akmSuite*: RsnSuiteView
    next*: UncheckedArray[uint8]

  WpsScanCallbackView {.packed.} = object
    result*: pointer
    reserved4*: array[2, uint8]
    capInfo*: uint16
    ssidPtr*: pointer
    ssidLen*: uint8
    reserved13*: array[3, uint8]
    rsnIe*: pointer
    wpaIe*: pointer
    wpsIe*: pointer

  WpsScanCallbackBuffer {.packed.} = object
    view*: WpsScanCallbackView
    tail*: array[112, uint8]

  WpsCallbacksView {.packed.} = object
    init*: pointer
    eapolHandler*: pointer
    staConnected*: pointer
    staAddConfirm*: pointer

  WpaParsedInfoView {.packed.} = object
    reserved0*: array[4, uint8]
    groupCipher*: uint8
    reserved5*: array[3, uint8]
    pairwiseCipher*: uint8
    reserved9*: array[3, uint8]
    keyMgmtByte*: uint8
    keyMgmtHigh*: uint8
    reserved14*: array[2, uint8]
    caps*: uint8
    reserved17*: array[11, uint8]
    vendorByte28*: uint8
    reserved29*: array[3, uint8]

  WpaParsedInfoBuffer {.packed.} = object
    view*: WpaParsedInfoView
    tail*: array[96, uint8]

  WpaCallbacksView {.packed.} = object
    init*: pointer
    deinit*: pointer
    scanSecurityNotify*: pointer
    keyWrite*: pointer
    reserved16*: pointer
    eapolHandler*: pointer
    beaconRegister*: pointer
    apStopped*: pointer
    reserved32*: pointer
    staAdd*: pointer
    disconnect*: pointer
    reserved44*: pointer
    parseSecurityIe*: pointer
    reserved52*: pointer
    getSaeFrame*: pointer
    reserved60*: pointer
    authTimeout*: pointer

  WpaBeaconRegisterParamView {.packed.} = object
    vifIdx*: uint8
    bssid*: array[6, uint8]
    reserved07*: array[33, uint8]
    rateCount*: uint32
    rates*: array[32, uint8]
    marker*: uint16
    ssid*: array[64, uint8]
    terminator*: uint8
    reserved143*: uint8

  WpaKeyWriteParamView {.packed.} = object
    vifIdx*: uint8
    staIdx*: uint8
    reserved02*: array[14, uint8]
    keyDataLen*: uint32
    keyMaterial*: array[38, uint8]
    ssid*: array[64, uint8]
    reserved122*: array[3, uint8]
    quickConn*: uint8
    reserved126*: array[2, uint8]

  WepKeyWriteParamView {.packed.} = object
    selector*: uint16
    reserved02*: array[2, uint8]
    keyLen*: uint8
    reserved05*: array[3, uint8]
    keyData*: array[44, uint8]
    cipherMode*: uint8
    instNbr*: uint8
    reserved54*: array[2, uint8]

  WpaScanSecurityNotifyView {.packed.} = object
    vifIdx*: uint8
    reserved1*: uint8
    macAddr*: array[6, uint8]
    bssid*: array[6, uint8]
    reserved14*: array[38, uint8]
    cipher*: uint8
    reserved53*: uint8
    keyMgmt*: uint16
    cipherPair*: uint16
    reserved58*: array[66, uint8]
    vendorByte124*: uint8
    reserved125*: array[3, uint8]

  TimIeView {.packed.} = object
    ie*: MacIeView
    dtimCount*: uint8
    dtimPeriod*: uint8
    bitmapControl*: uint8
    partialBitmap*: UncheckedArray[uint8]

  CsaIeView {.packed.} = object
    ie*: MacIeView
    switchMode*: uint8
    newChannel*: uint8
    switchCount*: uint8
    next*: UncheckedArray[uint8]

  ExtendedCsaIeView {.packed.} = object
    ie*: MacIeView
    switchMode*: uint8
    operatingClass*: uint8
    newChannel*: uint8
    switchCount*: uint8

  SecondaryChannelOffsetIeView {.packed.} = object
    ie*: MacIeView
    mode*: uint8

  WideBandwidthChannelSwitchIeView {.packed.} = object
    ie*: MacIeView
    bandwidthType*: uint8
    centerFreq1*: uint8
    centerFreq2*: uint8

  CsaOutputView {.packed.} = object
    csaPresent*: uint8
    secChanOffset*: uint8
    freq*: uint16
    newFreq*: uint16
    bwFreq*: uint16

  PowerConstraintOutputOverlay {.packed.} = object
    reserved00*: array[132, uint8]
    constraint*: uint8

  CountryRegOutputOverlay {.packed.} = object
    reserved00*: array[76, uint8]
    channelReg*: pointer

  CountryRegView {.packed.} = object
    countryHalf*: uint16
    environment*: uint8
    reserved03*: uint8
    maxPower*: uint8

  CountryTripletView {.packed.} = object
    firstChan*: uint8
    numChan*: uint8
    maxPower*: uint8

  TxlFrameDescView {.packed.} = object
    reserved0*: array[47, uint8]
    vifIdx*: uint8
    reserved1*: uint8
    staInfoIdx*: uint8
    reserved2*: array[48, uint8]
    retryCount*: uint8
    reserved3*: uint8
    statusByte*: uint8
    reserved4*: array[7, uint8]
    linkDesc*: pointer
    thd*: pointer
    reserved5*: array[92, uint8]
    callback*: pointer
    callbackArg*: pointer

  TxlThdProbeView {.packed.} = object
    reserved0*: array[16, uint8]
    payloadPtr*: pointer
    reserved1*: uint32
    bufLen*: uint32

  TdEntryView {.packed.} = object
    timerWord0*: uint32
    callback*: pointer
    env*: uint32
    timerWord12*: uint32
    period*: uint32
    timTime*: uint32
    rxCount*: uint32
    txCount*: uint32
    psRxCount*: uint32
    psTxCount*: uint32
    vifIdx*: uint8
    prevFlags*: uint8
    active*: uint8
    endActive*: uint8

  TdConfigView {.packed.} = object
    threshold*: uint32
    period*: uint32

  MeEnvObj* = object
    data*: array[256, uint8]

template macIeAt(p: uint): ptr MacIeView =
  cast[ptr MacIeView](p)

template rateSetAt(p: pointer): ptr RateSetView =
  cast[ptr RateSetView](p)

template macIeDataAt(p: pointer): ptr MacIeDataView =
  cast[ptr MacIeDataView](p)

template timeoutIntervalIeAt(p: pointer): ptr TimeoutIntervalIeView =
  cast[ptr TimeoutIntervalIeView](p)

template timIeAt(p: pointer): ptr TimIeView =
  cast[ptr TimIeView](p)

template csaIeAt(p: pointer): ptr CsaIeView =
  cast[ptr CsaIeView](p)

template powerConstraintOutputAt(p: pointer): ptr PowerConstraintOutputOverlay =
  cast[ptr PowerConstraintOutputOverlay](p)

template countryRegOutputAt(p: pointer): ptr CountryRegOutputOverlay =
  cast[ptr CountryRegOutputOverlay](p)

template countryRegAt(p: pointer): ptr CountryRegView =
  cast[ptr CountryRegView](p)

template countryTripletAt(p: pointer): ptr CountryTripletView =
  cast[ptr CountryTripletView](p)

template ssidIeAt(p: pointer): ptr SsidIeView =
  cast[ptr SsidIeView](p)

template dsParamSetIeAt(p: pointer): ptr DsParamSetIeView =
  cast[ptr DsParamSetIeView](p)

template oneByteMacIeAt(p: pointer): ptr OneByteMacIeView =
  cast[ptr OneByteMacIeView](p)

template bssMaxIdlePeriodIeAt(p: pointer): ptr BssMaxIdlePeriodIeView =
  cast[ptr BssMaxIdlePeriodIeView](p)

template wmmInfoIeAt(p: pointer): ptr WmmInfoIeView =
  cast[ptr WmmInfoIeView](p)

template wmmParameterIeAt(p: pointer): ptr WmmParameterIeView =
  cast[ptr WmmParameterIeView](p)

template htCapIeAt(p: pointer): ptr HtCapIeView =
  cast[ptr HtCapIeView](p)

template htOperIeAt(p: pointer): ptr HtOperIeView =
  cast[ptr HtOperIeView](p)

template rsnCcmpPskIeAt(p: pointer): ptr RsnCcmpPskIeView =
  cast[ptr RsnCcmpPskIeView](p)

template rsnTkipCcmpIeAt(p: pointer): ptr RsnTkipCcmpIeView =
  cast[ptr RsnTkipCcmpIeView](p)

template wpaVendorIeAt(p: pointer): ptr WpaVendorIeView =
  cast[ptr WpaVendorIeView](p)

template wpaPskVendorIeAt(p: pointer): ptr WpaPskVendorIeView =
  cast[ptr WpaPskVendorIeView](p)

template hostTxProbeReqFrame(link: ptr HostTxLinkDescView): ptr ProbeReqFrameView =
  cast[ptr ProbeReqFrameView](addr link.macHeader[0])

template txlThdProbeAt(p: pointer): ptr TxlThdProbeView =
  cast[ptr TxlThdProbeView](p)

template wpaCallbacks(): ptr WpaCallbacksView =
  cast[ptr WpaCallbacksView](wpa_cbs)

template wpsCallbacks(): ptr WpsCallbacksView =
  cast[ptr WpsCallbacksView](wps_cbs)

proc le32*(rec: WmmAcParamRecord): uint32 {.inline.} =
  rec.raw[0].uint32 or
    (rec.raw[1].uint32 shl 8) or
    (rec.raw[2].uint32 shl 16) or
    (rec.raw[3].uint32 shl 24)

proc setLe32*(rec: var WmmAcParamRecord; value: uint32) {.inline.} =
  rec.raw[0] = (value and 0xFF'u32).uint8
  rec.raw[1] = ((value shr 8) and 0xFF'u32).uint8
  rec.raw[2] = ((value shr 16) and 0xFF'u32).uint8
  rec.raw[3] = ((value shr 24) and 0xFF'u32).uint8

proc keyMgmtLe*(info: ptr WpaParsedInfoView): uint32 {.inline.} =
  info.keyMgmtByte.uint32 or (info.keyMgmtHigh.uint32 shl 8)

template macIePayload(ie: ptr MacIeView): ptr UncheckedArray[uint8] =
  cast[ptr UncheckedArray[uint8]](cast[uint](ie) + sizeof(MacIeView).uint)

proc totalLen*(ie: ptr MacIeView): uint {.inline.} =
  sizeof(MacIeView).uint + ie.len.uint

template scanuResultAt(p: pointer): ptr ScanuResultEntry =
  cast[ptr ScanuResultEntry](p)

template scanuChannelConfig(): ptr ScanuChannelConfigOverlay =
  cast[ptr ScanuChannelConfigOverlay](addr meEnvView().chanConfig[0])

template scanuAddIeView(): ptr ScanuAddIeObj =
  cast[ptr ScanuAddIeObj](addr scanu_add_ie[0])

template scanuAddIeDataAddr(): uint =
  cast[uint](addr scanuAddIeView().ieData[0])

template scanProbeReqIeDataPtr(ie: var ScanProbeReqIeObj): pointer =
  addr ie.ieData[0]

template scanProbeReqIeDataPtr(ie: var ScanProbeReqIeObj, offset: uint16): pointer =
  addr ie.ieData[offset.int]

template scanProbeReqIeDataBase(ie: var ScanProbeReqIeObj): uint32 =
  cast[uint32](scanProbeReqIeDataPtr(ie))

template scanProbeReqIePayloadPtr(ie: var ScanProbeReqIeObj): pointer =
  addr ie.magic

template rxuMgtIndAt(p: pointer): ptr RxuMgtIndView =
  cast[ptr RxuMgtIndView](p)

proc rxuMgtIndIeStart(p: pointer): pointer {.inline.} =
  addr rxuMgtIndAt(p).ieData[0]

proc rxuMgtIndSsidLogPtr(rx: ptr RxuMgtIndView): pointer {.inline.} =
  cast[pointer](unsafeAddr rx.reserved3[8])

template phyRxVectorAt(p: pointer): ptr PhyRxVectorView =
  cast[ptr PhyRxVectorView](p)

proc rssiRaw*(rxv: ptr PhyRxVectorView): uint32 {.inline.} =
  (rxv.rssiHi.uint32 shl 8) or rxv.rssiLo.uint32

template macAddrAt(p: pointer): ptr MacAddrView =
  cast[ptr MacAddrView](p)

template macDataFrameAt(p: pointer): ptr MacDataFrameHeaderView =
  cast[ptr MacDataFrameHeaderView](p)

template macFrameControlAt(p: pointer): ptr MacFrameControlView =
  cast[ptr MacFrameControlView](p)

template mmieAt(p: pointer): ptr MmIeView =
  cast[ptr MmIeView](p)

template mmieMicWords(ie: ptr MmIeView): ptr UncheckedArray[uint32] =
  cast[ptr UncheckedArray[uint32]](addr ie.mic[0])

template macQosDataFrameAt(p: pointer): ptr MacQosDataFrameHeaderView =
  cast[ptr MacQosDataFrameHeaderView](p)

template macQos4AddrFrameAt(p: pointer): ptr MacQos4AddrFrameHeaderView =
  cast[ptr MacQos4AddrFrameHeaderView](p)

template rxFrameBufferChainAt(p: pointer): ptr RxFrameBufferChainView =
  cast[ptr RxFrameBufferChainView](p)

template rxFrameBufferRefAt(p: pointer): ptr RxFrameBufferRefView =
  cast[ptr RxFrameBufferRefView](p)

template rxDmaProgressDescAt(p: pointer): ptr RxDmaProgressDescView =
  cast[ptr RxDmaProgressDescView](p)

template rxMicFailureIndAt(p: pointer): ptr RxMicFailureIndView =
  cast[ptr RxMicFailureIndView](p)

template rxMicWordsAt(p: uint): ptr RxMicWordsView =
  cast[ptr RxMicWordsView](p)

template rxuMgtIndMsgAt(p: pointer): ptr RxuMgtIndMsgView =
  cast[ptr RxuMgtIndMsgView](p)

template authChallengeBodyAt(p: pointer): ptr AuthChallengeBodyView =
  cast[ptr AuthChallengeBodyView](p)

template managementReasonBodyAt(p: pointer): ptr ManagementReasonBodyView =
  cast[ptr ManagementReasonBodyView](p)

template rxEthernetRewriteHeaderAt(p: pointer): ptr RxEthernetRewriteHeaderView =
  cast[ptr RxEthernetRewriteHeaderView](p)

proc rxFramePayload(swdesc: ptr RxSwDescView): pointer {.inline.} =
  rxFrameBufferChainAt(swdesc.bufferChain).frameData

proc rxQosControl(frame: ptr MacDataFrameHeaderView; machdrLen: uint8): uint16 {.inline.} =
  if machdrLen >= sizeof(MacQos4AddrFrameHeaderView).uint8:
    macQos4AddrFrameAt(frame).qosCtrl
  else:
    macQosDataFrameAt(frame).qosCtrl

template rxFrameBytes(frame: pointer): ptr UncheckedArray[uint8] =
  cast[ptr UncheckedArray[uint8]](frame)

template rxFrameWords(frame: pointer): ptr UncheckedArray[uint32] =
  cast[ptr UncheckedArray[uint32]](frame)

proc rxFrameCursor(frame: pointer; offset: uint): pointer {.inline.} =
  cast[pointer](addr rxFrameBytes(frame)[offset])

proc copyRoundedRxWords(dst: pointer; src: pointer; byteLen: uint16) {.inline.} =
  let wordCount = (byteLen.uint32 + 3) shr 2
  let dstWords = rxFrameWords(dst)
  let srcWords = rxFrameWords(src)
  for w in 0'u32 ..< wordCount:
    dstWords[w] = srcWords[w]

proc rxMsduView(frame: ptr MacDataFrameHeaderView; machdrLen: uint8): ptr RxMsduSnapView {.inline.} =
  cast[ptr RxMsduSnapView](addr rxFrameBytes(frame)[machdrLen])

proc rxMsdu(frame: ptr MacDataFrameHeaderView; machdrLen: uint8): ptr LlcSnapHeaderView {.inline.} =
  addr rxMsduView(frame, machdrLen).snap

proc rxMsduPayload(msdu: ptr RxMsduSnapView): pointer {.inline.} =
  cast[pointer](addr msdu.payload[0])

proc rxSnapPrefixIs(msdu: ptr LlcSnapHeaderView;
                    oui2: uint8): bool {.inline.} =
  msdu.dsap == 0xAA'u8 and
    msdu.ssap == 0xAA'u8 and
    msdu.control == 0x03'u8 and
    msdu.oui[0] == 0'u8 and
    msdu.oui[1] == 0'u8 and
    msdu.oui[2] == oui2

proc rxSnapIsRfc1042(msdu: ptr LlcSnapHeaderView): bool {.inline.} =
  rxSnapPrefixIs(msdu, 0'u8)

proc rxSnapIsBridgeTunnel(msdu: ptr LlcSnapHeaderView): bool {.inline.} =
  rxSnapPrefixIs(msdu, 0xF8'u8)

proc rxSnapTraceLo(msdu: ptr LlcSnapHeaderView): uint32 {.inline.} =
  msdu.dsap.uint32 or
    (msdu.ssap.uint32 shl 8) or
    (msdu.control.uint32 shl 16) or
    (msdu.oui[0].uint32 shl 24)

proc rxSnapTraceHi(msdu: ptr LlcSnapHeaderView): uint32 {.inline.} =
  msdu.oui[1].uint32 or
    (msdu.oui[2].uint32 shl 8) or
    (msdu.ethertype.uint32 shl 16)

proc rxSecurityHeaderAt[T](frame: pointer; machdrLen: uint8): ptr T {.inline.} =
  cast[ptr T](addr rxFrameBytes(frame)[machdrLen])

proc rxEthernetRewriteHeader(frame: ptr MacDataFrameHeaderView; stripLen: uint8): ptr RxEthernetRewriteHeaderView {.inline.} =
  cast[ptr RxEthernetRewriteHeaderView](addr rxFrameBytes(frame)[stripLen.int - 14])

proc rxFrameBodyByte(frame: ptr MacDataFrameHeaderView; offset: uint8): uint8 {.inline.} =
  cast[ptr UncheckedArray[uint8]](frame)[offset]

proc rxFrameAtRef(buf: pointer): ptr MacDataFrameHeaderView {.inline.} =
  macDataFrameAt(rxFrameBufferRefAt(buf).frameData)

proc rxCopyAddr(dst: ptr array[6, uint8]; src: ptr array[6, uint8]) {.inline.} =
  dst[] = src[]

proc rxAddrPtr(src: ptr array[6, uint8]): pointer {.inline.} =
  cast[pointer](src)

template vifApBeaconFrameDesc(vif: ptr VifChannelView): ptr TxlFrameDescView =
  cast[ptr TxlFrameDescView](addr vif.staIdx)

proc lowLe*(mac: ptr MacAddrView): uint32 {.inline.} =
  mac.bytes[0].uint32 or (mac.bytes[1].uint32 shl 8) or
    (mac.bytes[2].uint32 shl 16) or (mac.bytes[3].uint32 shl 24)

proc highLe*(mac: ptr MacAddrView): uint32 {.inline.} =
  mac.bytes[4].uint32 or (mac.bytes[5].uint32 shl 8)

template tdEntryAt(p: pointer): ptr TdEntryView =
  cast[ptr TdEntryView](p)

proc clearTrafficCounters(td: ptr TdEntryView) {.inline.} =
  td.rxCount = 0
  td.txCount = 0
  td.psRxCount = 0
  td.psTxCount = 0

static:
  doAssert sizeof(ScanuResultEntry) == 28
  doAssert offsetof(ScanuResultEntry, bssid) == 0
  doAssert offsetof(ScanuResultEntry, chanPtr) == 8
  doAssert offsetof(ScanuResultEntry, valid) == 16
  doAssert offsetof(ScanuResultEntry, rssi) == 17
  doAssert offsetof(ScanuResultEntry, rawMsgPtr) == 24
  doAssert sizeof(ScanuEnvObj) == 240
  doAssert offsetof(ScanuEnvObj, paramPtr) == 0
  doAssert offsetof(ScanuEnvObj, entries) == 4
  doAssert offsetof(ScanuEnvObj, pendingRawMsg) == 172
  doAssert offsetof(ScanuEnvObj, requester) == 176
  doAssert offsetof(ScanuEnvObj, bssidFilterEnabled) == 180
  doAssert offsetof(ScanuEnvObj, scanBand) == 181
  doAssert offsetof(ScanuEnvObj, filterBssid) == 182
  doAssert offsetof(ScanuEnvObj, filterSsidLen) == 188
  doAssert offsetof(ScanuEnvObj, probeIeCopyDst) == 224
  doAssert offsetof(ScanuEnvObj, directedFound) == 228
  doAssert offsetof(ScanuEnvObj, joinRetryCount) == 229
  doAssert offsetof(ScanuEnvObj, extraIePtr) == 232
  doAssert offsetof(ScanuEnvObj, extraIeLen) == 236
  doAssert sizeof(ScanuChannelConfigOverlay) == 85
  doAssert offsetof(ScanuChannelConfigOverlay, entries) == 0
  doAssert offsetof(ScanuChannelConfigOverlay, count) == 84
  doAssert sizeof(ScanEnvObj) == 24
  doAssert sizeof(ScanProbeReqIeObj) == 236
  doAssert offsetof(ScanProbeReqIeObj, ieData) == 36
  doAssert sizeof(ScanuAddIeObj) == 216
  doAssert offsetof(ScanuAddIeObj, ieData) == 16
  doAssert sizeof(ChanScanReqPayload) == 32
  doAssert sizeof(ChanScanAbortPayload) == 20
  doAssert sizeof(ProbeReqFixedFrame) == 26
  doAssert offsetof(ProbeReqFrameView, ssidData) == 26
  doAssert sizeof(RxuMgtIndView) == 68
  doAssert offsetof(RxuMgtIndView, reserved3) + 8 == 62
  doAssert offsetof(RxuMgtIndView, ieData) == 68
  doAssert sizeof(PhyRxVectorView) == 45
  doAssert sizeof(MacAddrView) == 6
  doAssert sizeof(MacIeView) == 2
  doAssert sizeof(MmIeView) == 18
  doAssert offsetof(MmIeView, ie) == 0
  doAssert offsetof(MmIeView, keyId) == 2
  doAssert offsetof(MmIeView, ipn) == 4
  doAssert offsetof(MmIeView, mic) == 10
  doAssert offsetof(RateSetView, rates) == 1
  doAssert offsetof(MacIeDataView, data) == 2
  doAssert offsetof(TimeoutIntervalIeView, intervalType) == 2
  doAssert offsetof(TimeoutIntervalIeView, intervalValue) == 3
  doAssert sizeof(TimeoutIntervalIeView) == 7
  doAssert offsetof(SsidIeView, data) == 2
  doAssert sizeof(DsParamSetIeView) == 3
  doAssert offsetof(DsParamSetIeView, currentChannel) == 2
  doAssert offsetof(DsParamSetIeView, next) == 3
  doAssert sizeof(OneByteMacIeView) == 3
  doAssert offsetof(OneByteMacIeView, value) == 2
  doAssert offsetof(OneByteMacIeView, next) == 3
  doAssert sizeof(BssMaxIdlePeriodIeView) == 5
  doAssert offsetof(BssMaxIdlePeriodIeView, idlePeriod) == 2
  doAssert offsetof(BssMaxIdlePeriodIeView, idleOptions) == 4
  doAssert sizeof(WmmInfoIeView) == 9
  doAssert offsetof(WmmInfoIeView, qosInfo) == 8
  doAssert offsetof(WmmInfoIeView, next) == 9
  doAssert sizeof(WmmAcParamRecord) == 4
  doAssert offsetof(WmmParameterIeView, qosInfo) == 8
  doAssert offsetof(WmmParameterIeView, ac) == 10
  doAssert sizeof(WmmParameterIeView) == 26
  doAssert offsetof(HtCapIeView, capInfo) == 2
  doAssert offsetof(HtCapIeView, ampduParams) == 4
  doAssert offsetof(HtCapIeView, mcsSet) == 5
  doAssert offsetof(HtCapIeView, extCap) == 21
  doAssert offsetof(HtCapIeView, txBfCapsLo) == 23
  doAssert offsetof(HtCapIeView, aselCap) == 27
  doAssert sizeof(HtCapIeView) == 28
  doAssert offsetof(HtCapIeView, next) == 28
  doAssert offsetof(HtOperIeView, primaryChannel) == 2
  doAssert offsetof(HtOperIeView, secondaryOffset) == 3
  doAssert offsetof(HtOperIeView, htProtection) == 4
  doAssert offsetof(HtOperIeView, operationMode) == 5
  doAssert offsetof(HtOperIeView, basicMcsSet) == 8
  doAssert sizeof(HtOperIeView) == 24
  doAssert offsetof(HtOperIeView, next) == 24
  doAssert sizeof(RsnSuiteView) == 4
  doAssert offsetof(RsnCcmpPskIeView, groupCipher) == 4
  doAssert offsetof(RsnCcmpPskIeView, pairwiseCipher) == 10
  doAssert offsetof(RsnCcmpPskIeView, akmSuite) == 16
  doAssert offsetof(RsnCcmpPskIeView, capabilities) == 20
  doAssert sizeof(RsnCcmpPskIeView) == 22
  doAssert offsetof(RsnCcmpPskIeView, next) == 22
  doAssert offsetof(RsnTkipCcmpIeView, pairwiseCipher) == 10
  doAssert offsetof(RsnTkipCcmpIeView, akmCount) == 18
  doAssert offsetof(RsnTkipCcmpIeView, akmSuite) == 20
  doAssert offsetof(RsnTkipCcmpIeView, capabilities) == 24
  doAssert sizeof(RsnTkipCcmpIeView) == 26
  doAssert offsetof(RsnTkipCcmpIeView, next) == 26
  doAssert offsetof(WpaVendorIeView, vendorType) == 2
  doAssert offsetof(WpaVendorIeView, version) == 6
  doAssert offsetof(WpaVendorIeView, groupCipher) == 8
  doAssert offsetof(WpaVendorIeView, pairwiseCount) == 12
  doAssert offsetof(WpaVendorIeView, pairwiseCipher) == 14
  doAssert offsetof(WpaVendorIeView, akmCount) == 22
  doAssert offsetof(WpaVendorIeView, akmSuite) == 24
  doAssert sizeof(WpaVendorIeView) == 28
  doAssert offsetof(WpaVendorIeView, next) == 28
  doAssert offsetof(WpaPskVendorIeView, vendorType) == 2
  doAssert offsetof(WpaPskVendorIeView, version) == 6
  doAssert offsetof(WpaPskVendorIeView, groupCipher) == 8
  doAssert offsetof(WpaPskVendorIeView, pairwiseCount) == 12
  doAssert offsetof(WpaPskVendorIeView, pairwiseCipher) == 14
  doAssert offsetof(WpaPskVendorIeView, akmCount) == 18
  doAssert offsetof(WpaPskVendorIeView, akmSuite) == 20
  doAssert sizeof(WpaPskVendorIeView) == 24
  doAssert offsetof(WpaPskVendorIeView, next) == 24
  doAssert offsetof(WpsScanCallbackView, capInfo) == 6
  doAssert offsetof(WpsScanCallbackView, ssidPtr) == 8
  doAssert offsetof(WpsScanCallbackView, ssidLen) == 12
  doAssert offsetof(WpsScanCallbackView, rsnIe) == 16
  doAssert offsetof(WpsScanCallbackView, wpaIe) == 20
  doAssert offsetof(WpsScanCallbackView, wpsIe) == 24
  doAssert sizeof(WpsScanCallbackView) == 28
  doAssert sizeof(WpsScanCallbackBuffer) == 140
  doAssert offsetof(WpsCallbacksView, init) == 0
  doAssert offsetof(WpsCallbacksView, eapolHandler) == 4
  doAssert offsetof(WpsCallbacksView, staConnected) == 8
  doAssert offsetof(WpsCallbacksView, staAddConfirm) == 12
  doAssert offsetof(WpaParsedInfoView, groupCipher) == 4
  doAssert offsetof(WpaParsedInfoView, pairwiseCipher) == 8
  doAssert offsetof(WpaParsedInfoView, keyMgmtByte) == 12
  doAssert offsetof(WpaParsedInfoView, keyMgmtHigh) == 13
  doAssert offsetof(WpaParsedInfoView, caps) == 16
  doAssert offsetof(WpaParsedInfoView, vendorByte28) == 28
  doAssert sizeof(WpaParsedInfoView) == 32
  doAssert sizeof(WpaParsedInfoBuffer) == 128
  doAssert offsetof(WpaCallbacksView, init) == 0
  doAssert offsetof(WpaCallbacksView, deinit) == 4
  doAssert offsetof(WpaCallbacksView, scanSecurityNotify) == 8
  doAssert offsetof(WpaCallbacksView, keyWrite) == 12
  doAssert offsetof(WpaCallbacksView, eapolHandler) == 20
  doAssert offsetof(WpaCallbacksView, beaconRegister) == 24
  doAssert offsetof(WpaCallbacksView, apStopped) == 28
  doAssert offsetof(WpaCallbacksView, staAdd) == 36
  doAssert offsetof(WpaCallbacksView, disconnect) == 40
  doAssert offsetof(WpaCallbacksView, parseSecurityIe) == 48
  doAssert offsetof(WpaCallbacksView, getSaeFrame) == 56
  doAssert offsetof(WpaCallbacksView, authTimeout) == 64
  doAssert sizeof(WpaBeaconRegisterParamView) == 144
  doAssert offsetof(WpaBeaconRegisterParamView, bssid) == 1
  doAssert offsetof(WpaBeaconRegisterParamView, rateCount) == 40
  doAssert offsetof(WpaBeaconRegisterParamView, rates) == 44
  doAssert offsetof(WpaBeaconRegisterParamView, marker) == 76
  doAssert offsetof(WpaBeaconRegisterParamView, ssid) == 78
  doAssert offsetof(WpaBeaconRegisterParamView, terminator) == 142
  doAssert sizeof(WpaKeyWriteParamView) == 128
  doAssert offsetof(WpaKeyWriteParamView, staIdx) == 1
  doAssert offsetof(WpaKeyWriteParamView, keyDataLen) == 16
  doAssert offsetof(WpaKeyWriteParamView, keyMaterial) == 20
  doAssert offsetof(WpaKeyWriteParamView, ssid) == 58
  doAssert offsetof(WpaKeyWriteParamView, quickConn) == 125
  doAssert sizeof(WepKeyWriteParamView) == 56
  doAssert offsetof(WepKeyWriteParamView, keyLen) == 4
  doAssert offsetof(WepKeyWriteParamView, keyData) == 8
  doAssert offsetof(WepKeyWriteParamView, cipherMode) == 52
  doAssert offsetof(WepKeyWriteParamView, instNbr) == 53
  doAssert offsetof(WpaScanSecurityNotifyView, macAddr) == 2
  doAssert offsetof(WpaScanSecurityNotifyView, bssid) == 8
  doAssert offsetof(WpaScanSecurityNotifyView, cipher) == 52
  doAssert offsetof(WpaScanSecurityNotifyView, keyMgmt) == 54
  doAssert offsetof(WpaScanSecurityNotifyView, cipherPair) == 56
  doAssert offsetof(WpaScanSecurityNotifyView, vendorByte124) == 124
  doAssert sizeof(WpaScanSecurityNotifyView) == 128
  doAssert offsetof(HostapdOpsView, eapolRx) == 44
  doAssert offsetof(TimIeView, dtimCount) == 2
  doAssert offsetof(TimIeView, dtimPeriod) == 3
  doAssert offsetof(TimIeView, bitmapControl) == 4
  doAssert offsetof(TimIeView, partialBitmap) == 5
  doAssert sizeof(CsaIeView) == 5
  doAssert offsetof(CsaIeView, switchMode) == 2
  doAssert offsetof(CsaIeView, newChannel) == 3
  doAssert offsetof(CsaIeView, switchCount) == 4
  doAssert offsetof(CsaIeView, next) == 5
  doAssert sizeof(ExtendedCsaIeView) == 6
  doAssert offsetof(ExtendedCsaIeView, switchMode) == 2
  doAssert offsetof(ExtendedCsaIeView, operatingClass) == 3
  doAssert offsetof(ExtendedCsaIeView, newChannel) == 4
  doAssert offsetof(ExtendedCsaIeView, switchCount) == 5
  doAssert sizeof(SecondaryChannelOffsetIeView) == 3
  doAssert sizeof(WideBandwidthChannelSwitchIeView) == 5
  doAssert sizeof(CsaOutputView) == 8
  doAssert offsetof(PowerConstraintOutputOverlay, constraint) == 132
  doAssert offsetof(CountryRegOutputOverlay, channelReg) == 76
  doAssert offsetof(CountryRegView, environment) == 2
  doAssert offsetof(CountryRegView, maxPower) == 4
  doAssert sizeof(CountryTripletView) == 3
  doAssert offsetof(CountryTripletView, numChan) == 1
  doAssert offsetof(CountryTripletView, maxPower) == 2
  doAssert sizeof(TxlFrameDescView) == 216
  doAssert offsetof(TxlFrameDescView, vifIdx) == 47
  doAssert offsetof(TxlFrameDescView, staInfoIdx) == 49
  doAssert offsetof(TxlFrameDescView, retryCount) == 98
  doAssert offsetof(TxlFrameDescView, statusByte) == 100
  doAssert offsetof(TxlFrameDescView, linkDesc) == 108
  doAssert offsetof(TxlFrameDescView, thd) == 112
  doAssert offsetof(TxlFrameDescView, callback) == 208
  doAssert offsetof(TxlFrameDescView, callbackArg) == 212
  doAssert sizeof(TxlThdProbeView) == 28
  doAssert sizeof(TdEntryView) == 44
  doAssert offsetof(TdEntryView, vifIdx) == 40
  doAssert offsetof(TdEntryView, active) == 42
  doAssert offsetof(TdEntryView, endActive) == 43
  doAssert sizeof(TdConfigView) == 8
  doAssert offsetof(BlOpsDataView, macWord0) == 16
  doAssert offsetof(BlOpsDataView, beaconTimeoutConfig) == 24
  doAssert offsetof(BlOpsDataView, beaconProbeCountdown) == 32
  doAssert offsetof(BlOpsDataView, adapterTimingConfig44) == 44

var WPA_OUI* = [0x00'u8, 0x50, 0xF2, 0x01]
var WMM_OUI* = [0x00'u8, 0x50, 0xF2, 0x02, 0x01]
var WPS_OUI* = [0x00'u8, 0x50, 0xF2, 0x04]

# Forward-reference to the broadcast MAC global (real storage at end of file).
# me_build_beacon/me_build_probe_rsp reference it before it is defined.
var mac_addr_bcst_fwd {.importc: "mac_addr_bcst", nodecl.}: array[6, uint8]

# mac_id2rate: Rate ID to 802.11 rate value mapping (12 entries)
# Blob hex: 82 84 8b 96 0c 12 18 24 30 48 60 6c
var mac_id2rate* {.exportc.}: array[12, uint8] = [
  0x82'u8, 0x84, 0x8B, 0x96, 0x0C, 0x12, 0x18, 0x24,
  0x30, 0x48, 0x60, 0x6C
]

const
  IE_ID_SSID* = 0'u8
  IE_ID_SUPPORTED_RATES* = 1'u8
  IE_ID_DS_PARAM* = 3'u8
  IE_ID_RSN* = 48'u8
  IE_ID_HT_CAP* = 45'u8
  IE_ID_VENDOR* = 221'u8
  IE_LEN_DS_PARAM* = 1'u8
  IE_LEN_HT_CAP* = 26'u8
  PROBE_REQ_SUPPORTED_RATE_COUNT* = 8'u8

