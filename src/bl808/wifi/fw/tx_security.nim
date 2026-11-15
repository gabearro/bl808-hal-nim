## Private key bindings for four host slots, four internal slots, and a beacon.
const TxSecurityReservationCount = 9

type TxSecurityReservation = object
  descriptor: pointer
  key: ptr VifKeySlotView
  revision, clock: uint64
  keyIndex: int
  vif, station, cipher, keyId: uint8
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
  if desc == nil or desc.vifIdx >= MAX_VIFS.uint8 or
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
  txSecurityReservations[index] = binding
  true

proc txSecurityCurrent(desc: ptr HostTxDescView): bool =
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
      binding.key.staIdx == binding.keyId and rxKeyRevision >= binding.clock and
      (txSecurityUpdating and (1'u32 shl binding.keyIndex)) == 0 and
      rxKeyLastChanged[binding.keyIndex] == binding.revision
  true
