"""Check TX completion trigger routing and ownership across diagnostic callbacks."""

from pathlib import Path
import re

import pytest

from test_wifi_disconnect_tx import FW, procedure
from test_wifi_frame_ownership import DMA_INVALIDATION_STUBS
from test_wifi_message_allocation import run_program
from test_wifi_tx_backup import PLATFORM


def source() -> str:
    code = PLATFORM.replace(DMA_INVALIDATION_STUBS, "").replace(
        "    queueFirst, bufDesc, hwDesc, callback: pointer",
        "    link: CoListHdr\n    queueFirst, bufDesc, hwDesc, callback: pointer",
    ).replace(
        "    frameLen, seqPassthrough: uint16",
        "    usedFlag: uint8\n    frameLen, seqPassthrough: uint16",
    )
    code = "import std/strutils\nvar onTrace: proc(label: string)\nvar onStatus, onPublish: proc()\n" + code
    code = code.replace(procedure(code, "hostTxHwDescAt"), r'''
var dmaHeads, secondary: array[3, HostTxHwDescView]
proc hostTxHwDescAt(p: pointer): ptr HostTxHwDescView =
  for i in 0 .. 2:
    if p == cast[pointer](0x1000 + i * 0x100): return addr dmaHeads[i]
    if p == cast[pointer](0x2000 + i * 0x100): return addr secondary[i]
  cast[ptr HostTxHwDescView](p)
''', 1)
    code = code.replace(procedure(code, "nimFwMgmtFcTrace"),
                        "proc nimFwMgmtFcTrace(fc: uint8): bool = fc == 0xB0\n", 1)
    for name in ("nimFwTrace2U32", "nimFwConnectTrace2U32"):
        code = code.replace(procedure(code, name), f'''
proc {name}(label: string; a, b: uint32) =
  if onTrace != nil: onTrace(label)
''', 1)
    code = code.replace(procedure(code, "machwTxStatus"), r'''
var ready, acknowledged: uint32
var readyAcks: int
proc machwTxStatus(): uint32 =
  result = ready
  if onStatus != nil: onStatus()
proc machwTxReadyAck(mask: uint32) =
  inc readyAcks
  acknowledged = acknowledged or mask
  ready = ready and not mask
''', 1)
    code += r'''
var routed: seq[tuple[descriptor: pointer, host: bool, status: uint32]]
proc co_list_pop_front(list: ptr CoList): pointer =
  result = list.first
  if result != nil:
    list.first = cast[ptr CoListHdr](result).next
    if list.first == nil: list.last = nil
proc txl_tx_desc_pointer_plausible(p: pointer): bool =
  for i in 0 .. 2:
    if p == (addr descs[i]): return true
proc txl_frame_desc_valid(p: pointer): bool = p == (addr descs[0])
proc assert_err(file, condition: cstring; line: int) = doAssert false
proc txl_frame_cfm(p: pointer)
proc txl_cfm_push(p: pointer; status, ac: uint32)
'''
    tx = (FW / "tx_layer.nim").read_text()
    for name in ("txlInvalidateDmaFrame", "txlInvalidateDmaAc", "txlInvalidateDmaVif",
                 "txlInvalidateDmaStation", "txlInvalidateDmaAll", "txlInvalidateDmaPool"):
        code += procedure(tx, name)
    code += r'''
proc txl_frame_cfm(p: pointer) =
  txlInvalidateDmaFrame(p)
  routed.add((p, false, hostTxHwDescAt(hostTxDescAt(p).hwDesc).confirmStatus))
  if onPublish != nil: onPublish()
proc txl_cfm_push(p: pointer; status, ac: uint32) =
  txlInvalidateDmaFrame(p)
  routed.add((p, true, status))
  if onPublish != nil: onPublish()
'''
    body = procedure(tx, "txl_transmit_trigger")
    debug = "\nvar\n" + "".join(
        f"  {name}: uint32\n" for name in sorted(set(re.findall(r"\bnimFwDbg\w+", body)))
    )
    validation = procedure(tx, "txlTriggerFrameCurrent") if "proc txlTriggerFrameCurrent(" in tx else ""
    return code + debug + validation + body + r'''
proc setup(ac: int; host = false; secondaryState = 0) =
  controls = default(typeof(controls))
  descs = default(typeof(descs))
  hw = default(typeof(hw))
  links = default(typeof(links))
  dmaHeads = default(typeof(dmaHeads))
  secondary = default(typeof(secondary))
  ready = 1'u32 shl (ac + 6)
  acknowledged = 0
  readyAcks = 0
  aggActive = 0x1F
  routed.setLen(0)
  timers.setLen(0)
  assertLines.setLen(0)
  onTrace = nil
  onStatus = nil
  onPublish = nil
  interruptsEnabled = true
  txActiveDmaOwner = nil
  txActiveTriggerOwner = nil
  for i in 0 .. 2:
    descs[i].hwDesc = addr hw[i]
    descs[i].bufDesc = addr links[i]
    descs[i].vifIdx = 1
    descs[i].staInfoIdx = 3
    links[i].macHeader[0] = 0xB0
    hw[i].txConfirmDescPtr = (0x1000 + i * 0x100).uint32
    hw[i].confirmStatus = 0x80800000'u32
    if host: descs[i].queueFirst = cast[pointer](1)
    if secondaryState != 0:
      hw[i].secondaryTxHwDescPtr = (0x2000 + i * 0x100).uint32
      secondary[i].controlFlags = if secondaryState == 1: 0 else: 0x80000000'u32
  controls[ac].pending.first = addr descs[0]
  controls[ac].pending.last = addr descs[0]
'''


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_trigger_preserves_vendor_routes_and_deadlines(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
const timeouts = [200000'u32, 2000000, 400000, 200000, 50000]
for ac in 0 .. 4:
  for host in [false, true]:
    for state in 0 .. 2:
      for incoming in [false, true]:
        setup(ac, host, state)
        interruptsEnabled = incoming
        txl_transmit_trigger()
        doAssert acknowledged == (1'u32 shl (ac + 6))
        doAssert timers == @[(ac.uint32, timerBase + timeouts[ac])]
        doAssert dmaHeads[0].status == 0x80800000'u32
        doAssert routed.len == (state != 1).int
        if state != 1:
          doAssert routed[0] == (cast[pointer](addr descs[0]), host, 0x80800000'u32)
          doAssert controls[ac].pending.first == nil
        else:
          doAssert controls[ac].pending.first == addr descs[0]
        doAssert interruptsEnabled == incoming and txActiveTriggerOwner == nil
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_trace_retirement_stops_old_trigger(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for marker in ["txtrig_desc", "txtrig_dma", "txtrig_route"]:
  for retirement in 0 .. 5:
    setup(2)
    var fired = false
    onTrace = proc(label: string) =
      if fired or not label.contains(marker): return
      fired = true
      doAssert controls[2].pending.first == addr descs[0]
      case retirement
      of 0: txlInvalidateDmaFrame(addr descs[0])
      of 1: txlInvalidateDmaAc(2)
      of 2: txlInvalidateDmaVif(1)
      of 3: txlInvalidateDmaStation(3)
      of 4: txlInvalidateDmaAll()
      else: txlInvalidateDmaPool()
      hw[0].txConfirmDescPtr = 0x1100
      hw[0].confirmStatus = 0x12345678
      controls[2].pending.first = addr descs[1]
      controls[2].pending.last = addr descs[1]
      dmaHeads[0].status = 0
      dmaHeads[1].status = 0
    txl_transmit_trigger()
    doAssert fired and routed.len == 0 and timers.len == 0
    doAssert controls[2].pending.first == addr descs[1]
    doAssert dmaHeads[0].status == 0 and dmaHeads[1].status == 0
    doAssert interruptsEnabled and txActiveTriggerOwner == nil
'''.replace("not label.contains(marker)", "marker notin label"))


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_recursive_trigger_does_not_complete_twice(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
setup(1, true)
var fired = false
onTrace = proc(label: string) =
  if fired: return
  fired = true
  ready = ready or (1'u32 shl 7)
  txl_transmit_trigger()
txl_transmit_trigger()
doAssert fired and routed.len == 1
doAssert timers.len == 1 and interruptsEnabled
doAssert readyAcks == 1
doAssert txActiveTriggerOwner == nil
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_rebinding_without_retirement_is_detected(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for variant in 0 .. 4:
  setup(2)
  var fired = false
  onTrace = proc(label: string) =
    if fired: return
    fired = true
    case variant
    of 0: descs[0].hwDesc = addr hw[1]
    of 1: descs[0].bufDesc = addr links[1]
    of 2: hw[0].txConfirmDescPtr = 0x1100
    of 3: descs[0].vifIdx = 0
    else: controls[2].pending.first = addr descs[1]
  txl_transmit_trigger()
  doAssert fired and routed.len == 0 and timers.len == 0
  doAssert dmaHeads[0].status == 0 and dmaHeads[1].status == 0
  doAssert interruptsEnabled and txActiveTriggerOwner == nil
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_reset_during_initial_status_read_is_not_acknowledged(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
setup(3)
onStatus = proc() = txlInvalidateDmaAll()
txl_transmit_trigger()
doAssert acknowledged == 0 and routed.len == 0 and timers.len == 0
doAssert controls[3].pending.first == addr descs[0]
doAssert interruptsEnabled and txActiveTriggerOwner == nil
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_teardown_after_publication_keeps_new_ac_state(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for variant in 0 .. 3:
  setup(2)
  onPublish = proc() =
    case variant
    of 0: txlInvalidateDmaAc(2)
    of 1: txlInvalidateDmaVif(1)
    of 2: txlInvalidateDmaStation(3)
    else: txlInvalidateDmaAll()
    controls[2].current = cast[pointer](0x777)
    controls[2].pending.first = addr descs[1]
    controls[2].pending.last = addr descs[1]
  txl_transmit_trigger()
  doAssert routed.len == 1 and timers.len == 0
  doAssert controls[2].current == cast[pointer](0x777)
  doAssert controls[2].pending.first == addr descs[1]
  doAssert interruptsEnabled and txActiveTriggerOwner == nil
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_trigger_and_backup_invalidation_are_independent(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
setup(2)
var backup = TxDmaOwner(desc: addr descs[1], ac: 4, vif: 0, station: 1)
txActiveDmaOwner = addr backup
onTrace = proc(label: string) =
  txlInvalidateDmaFrame(addr descs[1])
  doAssert backup.cancelled and not txActiveTriggerOwner.cancelled
txl_transmit_trigger()
doAssert routed.len == 1 and timers.len == 1
doAssert txActiveDmaOwner == (addr backup) and txActiveTriggerOwner == nil
txActiveDmaOwner = nil
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_highest_ready_ac_drains_its_chain_only(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
setup(3, true)
ready = ready or (1'u32 shl 7)
descs[0].link.next = addr descs[1]
controls[3].pending.last = addr descs[1]
controls[1].pending.first = addr descs[2]
controls[1].pending.last = addr descs[2]
txl_transmit_trigger()
doAssert routed.len == 2 and timers.len == 2
doAssert routed[0].descriptor == addr descs[0]
doAssert routed[1].descriptor == addr descs[1]
doAssert ready == (1'u32 shl 7) and readyAcks == 1
doAssert controls[1].pending.first == addr descs[2]
doAssert interruptsEnabled and txActiveTriggerOwner == nil
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_connect_trace_callback_can_cancel_trigger(tmp_path: Path, mode: str) -> None:
    code = source().replace("when defined(bl808WifiConnectTrace):", "when true:")
    run_program(tmp_path, mode, code + r'''
setup(0)
var fired = false
onTrace = proc(label: string) =
  if not label.startsWith("[WIFI-CT] txtrig_dma "): return
  fired = true
  txlInvalidateDmaFrame(addr descs[0])
  hw[0].txConfirmDescPtr = 0x1100
txl_transmit_trigger()
doAssert fired and routed.len == 0 and timers.len == 0
doAssert dmaHeads[0].status == 0 and dmaHeads[1].status == 0
doAssert interruptsEnabled and txActiveTriggerOwner == nil
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_invalid_hardware_and_exception_restore_owner(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for missingHardware in [false, true]:
  for incoming in [false, true]:
    setup(2)
    interruptsEnabled = incoming
    if missingHardware:
      descs[0].hwDesc = nil
    else:
      onTrace = proc(label: string) = raise newException(ValueError, "trace stopped")
    var raised = false
    try: txl_transmit_trigger()
    except ValueError: raised = true
    doAssert raised == not missingHardware
    doAssert assertLines.len == missingHardware.int
    doAssert controls[2].pending.first == addr descs[0]
    doAssert routed.len == 0 and timers.len == 0
    doAssert interruptsEnabled == incoming and txActiveTriggerOwner == nil
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_empty_and_not_ready_exits_restore_owner(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for variant in 0 .. 3:
  for incoming in [false, true]:
    setup(2)
    interruptsEnabled = incoming
    case variant
    of 0: ready = 0
    of 1: ready = 0xF8000
    of 2: hw[0].confirmStatus = 0
    else: controls[2].pending = default(CoList)
    txl_transmit_trigger()
    doAssert routed.len == 0 and timers.len == 0
    doAssert dmaHeads[0].status == 0
    doAssert readyAcks == (variant >= 2).int
    doAssert interruptsEnabled == incoming and txActiveTriggerOwner == nil
''')
