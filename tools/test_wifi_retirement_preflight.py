"""Keep TX queues owned until every selected access category has halted."""

from pathlib import Path

import pytest

from test_wifi_disconnect_tx import FW, procedure
from test_wifi_message_allocation import run_program


PLATFORM = r'''
const
  NUM_TX_QUEUES = 5
  MAX_VIFS = 2
  STA_INFO_TAB_ENTRIES = 7
  MACHW_INTC_BASE = 0x24B08000'u
type
  CoListHdr = object
    next: ptr CoListHdr
  CoList = object
    first, last: ptr CoListHdr
  HostTxDescView = object
    link: CoListHdr
    vifIdx, staInfoIdx: uint8
  IpcHostTxWrapperView = object
    link: CoListHdr
    txDesc: HostTxDescView
  TxFlushBatch = object
    previous: ptr TxFlushBatch
    ac: uint8
    status: uint32
    pending, confirmations, postponed: CoList
  TxDmaOwner = object
    desc: pointer
    ac: uint8
    cancelled: bool
  Control = object
    pending: CoList
    current: pointer
  Station = object
    postponedList: CoList
  Buffer = object
    backupQueues: array[NUM_TX_QUEUES, CoList]
  Binding = object
    descriptor, key: pointer
var
  controls: array[NUM_TX_QUEUES, Control]
  confirmations: array[NUM_TX_QUEUES, CoList]
  stations: array[STA_INFO_TAB_ENTRIES, Station]
  buffers: Buffer
  frameEnv: tuple[usedList: CoList]
  ipc: tuple[hostTxList: ptr CoList]
  frames: array[NUM_TX_QUEUES * 2, HostTxDescView]
  txSecurityReservations: array[NUM_TX_QUEUES * 2, Binding]
  txSecurityUpdating, txRetiringVifMask: uint32
  txRetiringVifEpochs, rxVifEpochs: array[MAX_VIFS, uint32]
  txlAcPending: array[NUM_TX_QUEUES, uint32]
  txlAcBusy: array[NUM_TX_QUEUES, bool]
  txActiveFlush: ptr TxFlushBatch
  txActiveDmaOwner: ptr TxDmaOwner
  targetKey, otherKey: byte
  irq: bool
  failHaltAt, completed: int
  expectedHalts, halted, detached, active: uint32
  phases: seq[string]
  onFlush: proc()
proc irqSave(): uint32 =
  result = if irq: 8'u32 else: 0'u32
  irq = false
proc irqRestore(saved: uint32) = irq = (saved and 8) != 0
proc txlFlushScopeExit(previous: ptr TxFlushBatch) = txActiveFlush = previous
proc hostTxDescAt(p: pointer): ptr HostTxDescView = cast[ptr HostTxDescView](p)
proc txControlAc(ac: uint32): ptr Control = addr controls[ac]
proc txCfmList(ac: uint32): ptr CoList = addr confirmations[ac]
proc txlBufferEnvView(): ptr Buffer = addr buffers
proc staInfoForIdx(station: uint8): ptr Station = addr stations[station]
proc txFrameEnv(): ptr typeof(frameEnv) = addr frameEnv
proc ipcEmbEnvView(): ptr typeof(ipc) = addr ipc
proc txlInvalidateDmaVif(vif: uint8) = discard
proc txlInvalidateDmaStation(station: uint8) = discard
proc txlInvalidateDmaAc(ac: uint8) =
  doAssert halted == expectedHalts, "detached an AC before all selected halts"
  detached = detached or (1'u32 shl ac)
  phases.add("detach" & $ac)
proc regRead(address: uint): uint32 = active
proc regWrite(address: uint; value: uint32) =
  if address == MACHW_INTC_BASE + 0x8C: active = value
proc txlResetting(): bool = false
proc txl_cntrl_halt_ac(ac: uint8): bool {.raises: [Exception].} =
  doAssert not irq
  doAssert detached == 0 and completed == 0, "halt entered after queue retirement"
  phases.add("halt" & $ac)
  if ac.int == failHaltAt:
    raise newException(ValueError, "halt did not complete")
  halted = halted or (1'u32 shl ac)
  true
proc txl_cfm_flush(ac: uint8; queue: ptr CoList; status: uint32) =
  doAssert halted == expectedHalts and status == 0x40000000'u32
  phases.add("flush" & $ac)
  if onFlush != nil:
    let action = onFlush
    onFlush = nil
    action()
  while queue.first != nil:
    inc completed
    queue.first = queue.first.next
  queue.last = nil
proc txlDrainRetiredPostponed(queue: ptr CoList) =
  doAssert queue.first == nil
proc txl_frame_evt() = doAssert frameEnv.usedList.first == nil
proc rxMgtKeyIndex(key: pointer): int =
  if key == (addr targetKey): 0 else: -1
proc assert_err(condition, file: cstring; line: int) =
  doAssert false, "unexpected access category"
'''


def source(tx: str | None = None, security: str | None = None) -> str:
    tx = tx if tx is not None else (FW / "tx_layer.nim").read_text()
    security = security if security is not None else (FW / "tx_security_update.nim").read_text()
    lists = (FW / "kernel_mac_channel.nim").read_text()
    code = PLATFORM
    for name in ["co_list_init", "co_list_push_back", "co_list_extract"]:
        code += procedure(lists, name)
    for name in [
        "txlDetachAc", "txl_cntrl_flush_ac", "txlQueueReferencesStation",
        "txlQueueReferencesVif", "txlHaltVifQueues", "txlHaltStationQueues",
        "txl_retire_vif", "txl_retire_station",
    ]:
        code += procedure(tx, name)
    code += security
    return code + r'''
proc setup(mask: uint32; incoming: bool) =
  controls = default(typeof(controls))
  confirmations = default(typeof(confirmations))
  stations = default(typeof(stations))
  buffers = default(Buffer)
  frames = default(typeof(frames))
  txSecurityReservations = default(typeof(txSecurityReservations))
  txlAcPending = default(typeof(txlAcPending))
  txlAcBusy = default(typeof(txlAcBusy))
  frameEnv = default(typeof(frameEnv))
  ipc.hostTxList = nil
  txActiveFlush = nil
  txActiveDmaOwner = nil
  txRetiringVifMask = 0
  txRetiringVifEpochs = default(typeof(txRetiringVifEpochs))
  rxVifEpochs = default(typeof(rxVifEpochs))
  txSecurityUpdating = 0
  failHaltAt = -1
  irq = incoming
  expectedHalts = mask
  halted = 0
  detached = 0
  active = 31
  completed = 0
  phases.setLen(0)
  onFlush = nil
  for ac in 0 ..< NUM_TX_QUEUES:
    let selected = (mask and (1'u32 shl ac)) != 0
    for index in [ac * 2, ac * 2 + 1]:
      frames[index].vifIdx = if selected: 1'u8 else: 0'u8
      frames[index].staInfoIdx = if selected: 2'u8 else: 3'u8
      txSecurityReservations[index] = Binding(descriptor: addr frames[index],
        key: (if selected: addr targetKey else: addr otherKey))
    co_list_push_back(addr controls[ac].pending, addr frames[ac * 2].link)
    co_list_push_back(addr confirmations[ac], addr frames[ac * 2 + 1].link)
    controls[ac].current = addr frames[ac * 2]
    buffers.backupQueues[ac] = controls[ac].pending
    txlAcPending[ac] = 1
    txlAcBusy[ac] = true
proc retire(kind: int) =
  # VIF and station retirement are called from IRQ-masked lifecycle paths.
  let saved = irqSave()
  defer: irqRestore(saved)
  var selected: uint8
  case kind
  of 0:
    doAssert txlHaltVifQueues(1, selected)
    txl_retire_vif(1, selected)
  of 1:
    doAssert txlHaltStationQueues(2, selected)
    txl_retire_station(2, selected)
  else:
    doAssert txSecurityBeginUpdate(addr targetKey)
    doAssert txSecurityUpdating == 1
    txSecurityEndUpdate(addr targetKey)
proc checkQueues(mask: uint32) =
  for ac in 0 ..< NUM_TX_QUEUES:
    if (mask and (1'u32 shl ac)) != 0:
      doAssert controls[ac].pending.first == nil and confirmations[ac].first == nil
      doAssert controls[ac].current == nil and buffers.backupQueues[ac].first == nil
      doAssert txlAcPending[ac] == 0 and not txlAcBusy[ac]
    else:
      doAssert controls[ac].pending.first == (addr frames[ac * 2].link)
      doAssert controls[ac].pending.last == (addr frames[ac * 2].link)
      doAssert confirmations[ac].first == (addr frames[ac * 2 + 1].link)
      doAssert confirmations[ac].last == (addr frames[ac * 2 + 1].link)
      doAssert controls[ac].current == (addr frames[ac * 2])
      doAssert buffers.backupQueues[ac].first == (addr frames[ac * 2].link)
      doAssert txlAcPending[ac] == 1 and txlAcBusy[ac]
'''


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_all_selected_halts_precede_retirement(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for kind in 0 .. 2:
  for mask in [0'u32, 1, 10, 21, 31]:
    for incoming in [false, true]:
      setup(mask, incoming)
      retire(kind)
      checkQueues(mask)
      doAssert halted == mask and detached == mask
      var selected = 0
      for ac in 0 ..< NUM_TX_QUEUES:
        if (mask and (1'u32 shl ac)) != 0: inc selected
      doAssert completed == selected * 2
      doAssert txSecurityUpdating == 0 and txActiveFlush == nil
      doAssert txRetiringVifMask == 0 and irq == incoming
''')


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_incomplete_halt_keeps_all_queues_owned(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for kind in 0 .. 2:
  for failAt in 0 ..< NUM_TX_QUEUES:
    for incoming in [false, true]:
      setup(31, incoming)
      failHaltAt = failAt
      var failed = false
      try: retire(kind)
      except ValueError: failed = true
      doAssert failed and detached == 0 and completed == 0
      checkQueues(0)
      doAssert txActiveFlush == nil and txSecurityUpdating == 0
      doAssert txRetiringVifMask == 0 and irq == incoming
      failHaltAt = -1
      phases.setLen(0)
      halted = 0
      retire(kind)
      checkQueues(31)
      doAssert completed == 10 and txSecurityUpdating == 0 and txActiveFlush == nil
''')


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_callback_submission_to_another_ac_survives(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for kind in 0 .. 2:
  for incoming in [false, true]:
    setup(31, incoming)
    var replacement = HostTxDescView(vifIdx: 0, staInfoIdx: 3)
    var observed = false
    onFlush = proc() =
      observed = true
      doAssert halted == 31 and detached == 31
      for ac in 0 ..< NUM_TX_QUEUES:
        doAssert controls[ac].pending.first == nil and confirmations[ac].first == nil
      co_list_push_back(addr controls[4].pending, addr replacement.link)
      controls[4].current = addr replacement
      buffers.backupQueues[4] = controls[4].pending
      txlAcPending[4] = 1
      txlAcBusy[4] = true
    retire(kind)
    doAssert observed and completed == 10
    doAssert controls[4].pending.first == (addr replacement.link)
    doAssert controls[4].pending.last == (addr replacement.link)
    doAssert controls[4].current == (addr replacement)
    doAssert buffers.backupQueues[4].first == (addr replacement.link)
    doAssert txlAcPending[4] == 1 and txlAcBusy[4]
    doAssert txActiveFlush == nil and txSecurityUpdating == 0 and irq == incoming
''')
