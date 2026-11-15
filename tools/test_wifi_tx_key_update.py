"""Quiesce key-bound TX queues before replacing or deleting a key."""

from pathlib import Path

import pytest

from test_wifi_aes_cmac import procedure
from test_wifi_message_allocation import run_program
from test_wifi_station_keys import FW, WRITE_PLATFORM, harness, proc_body
from test_wifi_tx_counter_limit import SETUP
from test_wifi_tx_security import program_source


def transaction_program(operation: str, mm_source: str | None = None) -> str:
    mm = mm_source if mm_source is not None else (FW / "kernel_mac_channel.nim").read_text()
    guard = r'''
var
  updateKey: pointer
  updateAllowed = true
  invalidateDuringUpdate: bool
proc txSecurityBeginUpdate(key: pointer): bool =
  doAssert not irq and key != nil
  if not updateAllowed: return false
  doAssert updateKey == nil
  updateKey = key
  event("quiesce", pointerAddrU32(key))
  if invalidateDuringUpdate: inc rxVifEpochs[0]
  true
proc txSecurityEndUpdate(key: pointer) =
  doAssert not irq and updateKey == key
  event("end", pointerAddrU32(key))
  updateKey = nil
'''
    if operation == "write":
        platform = WRITE_PLATFORM.replace(
            '  events.add((kind, value, extra))',
            '  if kind notin ["quiesce", "end"]: doAssert updateKey != nil, "key changed before TX quiescence"\n'
            '  events.add((kind, value, extra))',
        )
        checks = r'''
for incoming in [false, true]:
  for group in [false, true]:
    for cipher in [0'u8, 1, 2, 3, 5]:
      if cipher == 5 and not group: continue
      for failure in 0..4:
        setup(incoming)
        updateKey = nil
        updateAllowed = failure != 1
        invalidateDuringUpdate = failure == 2
        idleSucceeds = failure != 3
        completionSucceeds = failure != 4
        var req = requestFor(cipher, group)
        let expected = if group: cast[pointer](vifKeySlotPtr(vifChannelForIdx(0), req.addrIdx.uint))
          else: cast[pointer](addr sta_info_tab[0].keyArea[0])
        let result = mm_sec_machwkey_wr(addr req)
        doAssert irq == incoming and updateKey == nil
        if failure == 1:
          doAssert result == 0xFF and events.len == 0
        else:
          doAssert events[0] == ("quiesce", pointerAddrU32(expected), 0'u32)
          doAssert events[^1].kind == "end"
          if failure == 2:
            doAssert result == 0xFF and events.len == 2 and not installed
          elif cipher == 5:
            doAssert result != 0xFF and events.len == 3 and installed
          else:
            doAssert (result != 0xFF) == (failure == 0)
'''
        body = proc_body(mm, "mm_sec_machwkey_wr")
    else:
        from test_wifi_security_transactions import PLATFORM

        platform = PLATFORM.replace(
            '  events.add(name)',
            '  if name notin ["quiesce", "end"]: doAssert updateKey != nil, "key deleted before TX quiescence"\n'
            '  events.add(name)',
        )
        guard = guard.replace('event("quiesce", pointerAddrU32(key))', 'event("quiesce")')
        guard = guard.replace('event("end", pointerAddrU32(key))', 'event("end")')
        body = proc_body((FW / "sta_management.nim").read_text(), "sta_mgmt_del_key")
        body += proc_body(mm, "mmDeleteSecurityKey")
        checks = r'''
for incoming in [false, true]:
  for key in 0'u8 .. 18:
    for failure in 0..4:
      setup(incoming)
      updateKey = nil
      updateAllowed = failure != 1
      invalidateDuringUpdate = failure == 2
      idleOk = failure != 3
      doneOk = failure != 4
      if failure == 2:
        # Every selected descriptor belongs to this VIF for the epoch check.
        if key < 8: invalidateDuringUpdate = (key shr 2) == 0
        elif key < 15: sta_info_tab[key - 8].instNbr = 0
        else: invalidateDuringUpdate = (key - 15) div 2 == 0
      let oldVifs = vifs
      let oldStations = sta_info_tab
      let result = mmDeleteSecurityKey(key)
      doAssert irq == incoming and updateKey == nil
      if failure == 1:
        doAssert not result and events.len == 0
        doAssert oldVifs == vifs and oldStations == sta_info_tab
      else:
        doAssert events[0] == "quiesce" and events[^1] == "end"
        if invalidateDuringUpdate:
          doAssert not result and events.len == 2
          doAssert oldVifs == vifs and oldStations == sta_info_tab
        elif key > 14:
          doAssert result and events == @["quiesce", "vif", "end"]
        elif failure in [3, 4]:
          doAssert not result
        else:
          doAssert result
'''
    declarations, guard_body = guard.split("proc txSecurityBeginUpdate", 1)
    return declarations + harness(platform, "proc txSecurityBeginUpdate" + guard_body,
                                  body, tx_update_stubs=False) + checks


@pytest.mark.parametrize("operation", ["write", "delete"])
@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_key_transaction_quiescence(tmp_path: Path, operation: str, mode: str) -> None:
    run_program(tmp_path, mode, transaction_program(operation))


def queue_program() -> str:
    code = program_source()
    code = code.replace("  HostTxDescView = object\n", "  HostTxDescView = object\n    link: CoListHdr\n")
    old = procedure(code, "rxMgtKeyIndex")
    code = code.replace(old, """var keyTable: array[2, pointer]
proc rxMgtKeyIndex(key: pointer): int =
  for i, entry in keyTable:
    if key != nil and key == entry: return i
  -1
""", 1)
    code = r'''
type
  CoListHdr = object
    next: ptr CoListHdr
  CoList = object
    first, last: ptr CoListHdr
''' + code + SETUP + r'''
const NUM_TX_QUEUES = 5
const WifiHwPollLimit = 4'u32
const MACHW_INTC_BASE = 0x24B08000'u
type
  TxFlushBatch = object
    previous: ptr TxFlushBatch
    ac: uint8
    status: uint32
    pending, confirmations, postponed: CoList
  Control = object
    pending: CoList
    current: pointer
  TxDmaOwner = object
    desc: pointer
    ac: uint8
    cancelled: bool
  Buffer = object
    backupQueues: array[5, CoList]
var
  controls: array[5, Control]
  confirmations: array[5, CoList]
  buffers: Buffer
  txActiveFlush: ptr TxFlushBatch
  txActiveDmaOwner: ptr TxDmaOwner
  txActiveTriggerOwner: ptr TxDmaOwner
  txlAcPending: array[5, uint32]
  txlAcBusy: array[5, bool]
  halted, detached: uint32
  events: seq[string]
  onConfirmation: proc()
  txState: tuple[resetInProgress: uint8]
proc txControlAc(ac: uint32): ptr Control = addr controls[ac]
proc txCfmList(ac: uint32): ptr CoList = addr confirmations[ac]
proc txlBufferEnvView(): ptr Buffer = addr buffers
proc txControlEnv(): ptr typeof(txState) = addr txState
proc txlResetting(): bool = txState.resetInProgress != 0
proc noteHwWaitTimeout(address, mask: uint32) =
  doAssert false, "unexpected halt timeout"
proc hal_machw_disable_int() =
  doAssert false, "unexpected MAC recovery"
proc txlInvalidateDmaAll() = discard
proc ke_evt_set(mask: uint32) = discard
proc co_list_init(list: ptr CoList) = list[] = default(CoList)
proc txlFlushScopeExit(previous: ptr TxFlushBatch) = txActiveFlush = previous
proc assert_err(a, b: cstring; line: int) = doAssert false
proc regWrite(address: uint; value: uint32) =
  doAssert not interrupts
  if address == 0x24B08180'u:
    const masks = [0x10000'u32, 0x20000, 0x40000, 0x80000, 0x8000]
    for ac, mask in masks:
      if value == mask:
        halted = halted or (1'u32 shl ac)
        events.add("halt" & $ac)
  elif address == 0x24B08088'u:
    detached = detached or value
    events.add("detach" & $value)
proc regRead(address: uint): uint32 =
  doAssert not interrupts
  if address == 0x24B08188'u: 0'u32 else: 0x1F'u32
proc txl_cfm_flush(ac: uint8; list: ptr CoList; status: uint32) =
  while list.first != nil:
    doAssert not interrupts and status == 0x40000000'u32
    let node = list.first
    list.first = node.next
    if list.first == nil: list.last = nil
    events.add("complete" & $ac)
    if onConfirmation != nil: onConfirmation()
    txSecurityForget(node)
'''
    tx = (FW / "tx_layer.nim").read_text()
    code += procedure(tx, "txlInvalidateDmaAc")
    code += procedure(tx, "txl_cntrl_halt_ac")
    code += procedure(tx, "txlDetachAc")
    code += (FW / "tx_security_update.nim").read_text()
    return code + r'''
var
  frames: array[7, HostTxDescView]
  secondKey: VifKeySlotView
  secondKeys: KeyList
  ancestor: TxFlushBatch
proc queueReset(incoming: bool) =
  setup(2, 41, incoming)
  txState.resetInProgress = 0
  secondKey = key
  secondKeys.pairwiseKey = addr secondKey
  stations[4].keyMat = addr secondKeys
  keyTable = [cast[pointer](addr key), cast[pointer](addr secondKey)]
  txSecurityUpdating = 0
  controls = default(typeof(controls))
  confirmations = default(typeof(confirmations))
  buffers = default(Buffer)
  halted = 0
  detached = 0
  events.setLen(0)
  onConfirmation = nil
  frames = default(typeof(frames))
  ancestor = default(TxFlushBatch)
  txActiveFlush = addr ancestor
  txActiveDmaOwner = nil
  for i in 0..<frames.len:
    frames[i] = desc
    if i in [1, 4, 6]: frames[i].staInfoIdx = 4
    var extra: uint32
    doAssert txu_cntrl_sechdr_len_compute(addr frames[i], addr extra) == 8
  for ac in 0..4:
    let list = if ac == 3: addr confirmations[ac] else: addr controls[ac].pending
    list[] = CoList(first: addr frames[ac].link, last: addr frames[ac].link)
    controls[ac].current = cast[pointer](1)
    buffers.backupQueues[ac] = list[]
    txlAcBusy[ac] = true
    txlAcPending[ac] = 1

for incoming in [false, true]:
  queueReset(incoming)
  var calls = 0
  var fresh = desc
  onConfirmation = proc() =
    inc calls
    # ACs 0, 2, and 3 must all be idle/detached before the first callback.
    doAssert halted == 0x0D and detached == 0x0D
    doAssert not txSecurityCurrent(addr fresh)
    doAssert not txSecurityBeginUpdate(addr key)
    doAssert not txSecurityBind(addr fresh, addr key, false)
    doAssert txSecurityCurrent(addr frames[1])
    doAssert controls[1].pending.first == addr frames[1].link
    doAssert controls[4].pending.first == addr frames[4].link
    if calls == 1:
      # New unrelated work published by a callback survives the old flush.
      controls[0].pending = CoList(first: addr frames[6].link, last: addr frames[6].link)
  # Bind the private candidate so current() also tests the update gate.
  doAssert txSecurityBind(addr fresh, addr key, false)
  doAssert txSecurityBeginUpdate(addr key)
  doAssert calls == 3 and interrupts == incoming and txActiveFlush == addr ancestor
  doAssert controls[0].pending.first == addr frames[6].link
  doAssert (txSecurityUpdating and 1) != 0
  txSecurityReset()
  # Resetting the TX pool cannot clear an in-progress key-update gate.
  doAssert not txSecurityBind(addr fresh, addr key, false)
  txSecurityEndUpdate(addr key)
  doAssert txSecurityUpdating == 0 and interrupts == incoming
  doAssert txSecurityBind(addr fresh, addr key, false)

  queueReset(incoming)
  # An in-progress backup node can already have left the backup/pending list.
  controls[0].pending = default(CoList)
  controls[2].pending = default(CoList)
  confirmations[3] = default(CoList)
  var active = TxDmaOwner(desc: addr frames[5], ac: 2)
  txActiveDmaOwner = addr active
  doAssert txSecurityBeginUpdate(addr key)
  doAssert active.cancelled and halted == 4 and detached == 4
  txSecurityEndUpdate(addr key)
  doAssert interrupts == incoming

  queueReset(incoming)
  onConfirmation = proc() =
    onConfirmation = nil
    doAssert txSecurityBeginUpdate(addr secondKey)
    doAssert (txSecurityUpdating and 3) == 3
    txSecurityEndUpdate(addr secondKey)
    doAssert (txSecurityUpdating and 1) != 0
  doAssert txSecurityBeginUpdate(addr key)
  doAssert halted == 0x1F and detached == 0x1F
  txSecurityEndUpdate(addr key)
  doAssert txSecurityUpdating == 0 and txActiveFlush == addr ancestor
'''


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_key_bound_queues_quiesce(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, queue_program())
