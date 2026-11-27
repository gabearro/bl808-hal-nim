# Host DMA records, four internal frames, and a beacon can all retain a key.
const TxSecurityReservationCount =
  (when defined(bl808WifiSplitTxSlots): hostIpc.WifiTxDmaRecordCount else: 4) + 5

type TxSecurityReservation = object
  descriptor: pointer
  key: ptr VifKeySlotView
  revision, clock: uint64
  keyIndex: int
  vif, station, cipher, keyId, hwKeyIdx: uint8
  bip: bool

var txSecurityReservations {.wifiCtrl.}: array[TxSecurityReservationCount, TxSecurityReservation]
var txSecurityUpdating {.wifiCtrl.}: uint32

proc txSecurityKeyUpdatePending(key: pointer): bool =
  let saved = irqSave()
  {.emit: "__asm__ volatile(\"\" ::: \"memory\");".}
  defer:
    {.emit: "__asm__ volatile(\"\" ::: \"memory\");".}
    irqRestore(saved)
  let index = rxMgtKeyIndex(key)
  index >= 0 and (txSecurityUpdating and (1'u32 shl index)) != 0

proc txSecuritySelectedKey(desc: ptr HostTxDescView; bip: bool): ptr VifKeySlotView =
  if desc == nil or desc.vifIdx >= MAX_VIFS.uint8:
    return nil
  let vif = vifChannelForIdx(desc.vifIdx)
  if bip:
    return cast[ptr VifKeySlotView](vifKeyPointers(vif).groupKeyPtr)
  if desc.staInfoIdx >= STA_INFO_TAB_ENTRIES.uint8:
    return nil
  let sta = staInfoForIdx(desc.staInfoIdx)
  if sta.keyMat == nil:
    return nil
  if (vifKeyPointers(vif).flags and 2) != 0 and
      lmacGateHalfword(desc.frameLen) == sta.rateWord:
    return nil
  cast[ptr VifKeySlotView](txSecurityKeyListAt(sta.keyMat).pairwiseKey)

proc txSecurityReset() =
  let saved = irqSave()
  {.emit: "__asm__ volatile(\"\" ::: \"memory\");".}
  defer:
    {.emit: "__asm__ volatile(\"\" ::: \"memory\");".}
    irqRestore(saved)
  txSecurityReservations = default(typeof(txSecurityReservations))

proc txSecurityForget(desc: pointer) =
  let saved = irqSave()
  {.emit: "__asm__ volatile(\"\" ::: \"memory\");".}
  defer:
    {.emit: "__asm__ volatile(\"\" ::: \"memory\");".}
    irqRestore(saved)
  for binding in txSecurityReservations.mitems:
    if binding.descriptor == desc:
      binding = default(TxSecurityReservation)
      return

proc txSecurityBind(desc: ptr HostTxDescView; key: ptr VifKeySlotView; bip: bool): bool =
  let saved = irqSave()
  {.emit: "__asm__ volatile(\"\" ::: \"memory\");".}
  defer:
    {.emit: "__asm__ volatile(\"\" ::: \"memory\");".}
    irqRestore(saved)
  if desc == nil or (bip and key == nil) or desc.vifIdx >= MAX_VIFS.uint8 or
      (not bip and desc.staInfoIdx >= STA_INFO_TAB_ENTRIES.uint8) or
      txSecuritySelectedKey(desc, bip) != key:
    return false
  var keyIndex = -1
  if key != nil:
    keyIndex = rxMgtKeyIndex(key)
    if keyIndex < 0 or key.installed == 0 or
        (txSecurityUpdating and (1'u32 shl keyIndex)) != 0:
      return false
  var index = -1
  for i, binding in txSecurityReservations:
    if binding.descriptor == cast[pointer](desc):
      index = i
      break
    if index < 0 and binding.descriptor == nil:
      index = i
  if index < 0:
    return false
  var binding = TxSecurityReservation(descriptor: desc, key: key, keyIndex: keyIndex,
    vif: desc.vifIdx, station: desc.staInfoIdx, bip: bip, clock: rxKeyRevision)
  if key != nil:
    binding.revision = rxKeyLastChanged[keyIndex]
    binding.cipher = key.cipherType
    binding.keyId = key.staIdx
    binding.hwKeyIdx = key.keyIdx
  txSecurityReservations[index] = binding
  true

proc txSecurityIsInternalNull(desc: ptr HostTxDescView): bool =
  if desc.usedFlag != 0 or desc.queueFirst != nil or
      desc.bufDesc == nil or desc.hwDesc == nil:
    return false
  let link = hostTxLinkDescAt(desc.bufDesc)
  let header = addr link.macHeader[0]
  # txl_frame.o builds these with only a MAC header and no encryption.
  let headerLength = case macFrameControlAt(header).frameControl
    of 0x0148'u16: sizeof(MacDataFrameHeaderView).uint32
    of 0x01C8'u16, 0x02C8'u16: sizeof(MacQosDataFrameHeaderView).uint32
    else: return false
  let hw = hostTxHwDescAt(desc.hwDesc)
  let start = pointerAddrU32(header)
  hw.frameLen == headerLength + 4 and hw.payloadStart == start and
    hw.payloadEnd == start + headerLength - 1

proc txSecurityCurrent(desc: ptr HostTxDescView; allowInternalNull = false): bool =
  let saved = irqSave()
  {.emit: "__asm__ volatile(\"\" ::: \"memory\");".}
  defer:
    {.emit: "__asm__ volatile(\"\" ::: \"memory\");".}
    irqRestore(saved)
  for binding in txSecurityReservations:
    if binding.descriptor != cast[pointer](desc):
      continue
    if desc == nil or desc.vifIdx != binding.vif or desc.staInfoIdx != binding.station or
        txSecuritySelectedKey(desc, binding.bip) != binding.key:
      return false
    if binding.key == nil:
      return true
    return binding.key.installed != 0 and binding.key.cipherType == binding.cipher and
      binding.key.staIdx == binding.keyId and binding.key.keyIdx == binding.hwKeyIdx and
      rxKeyRevision >= binding.clock and
      (txSecurityUpdating and (1'u32 shl binding.keyIndex)) == 0 and
      rxKeyLastChanged[binding.keyIndex] == binding.revision
  if desc == nil or desc.vifIdx >= MAX_VIFS.uint8:
    return false
  if desc.staInfoIdx == 0xFF'u8:
    # Probe, beacon, AP response, and CTS frames can have no station key.
    if desc.queueFirst != nil or desc.bufDesc == nil or desc.hwDesc == nil:
      return false
    let hw = hostTxHwDescAt(desc.hwDesc)
    if hw.frameLen < 6: # Frame control plus FCS.
      return false
    let link = hostTxLinkDescAt(desc.bufDesc)
    let fc = macFrameControlAt(addr link.macHeader[0]).frameControl
    # Version 0, clear Protected bit, management or control (not data).
    return (fc and 0x400F'u16) in {0'u16, 4'u16}
  if desc.staInfoIdx >= STA_INFO_TAB_ENTRIES.uint8:
    return false
  (allowInternalNull and txSecurityIsInternalNull(desc)) or
    txSecuritySelectedKey(desc, false) == nil

proc txSecurityLengthsCurrent(desc: ptr HostTxDescView): tuple[header, tail: int] =
  let saved = irqSave()
  {.emit: "__asm__ volatile(\"\" ::: \"memory\");".}
  defer:
    {.emit: "__asm__ volatile(\"\" ::: \"memory\");".}
    irqRestore(saved)
  if not txSecurityCurrent(desc):
    return (-1, -1)
  for binding in txSecurityReservations:
    if binding.descriptor == cast[pointer](desc) and binding.bip:
      return (-1, -1)
  let key = txSecuritySelectedKey(desc, false)
  if key == nil:
    return (0, 0)
  case key.cipherType
  of 0, 3: (4, 4)
  of 1: (8, 12)
  of 2: (8, 8)
  else: (-1, -1)
