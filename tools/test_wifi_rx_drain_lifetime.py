"""Check nested lower-RX draining without consuming another active frame."""

from pathlib import Path

import pytest

from test_wifi_disconnect_tx import procedure
from test_wifi_message_allocation import run_program
from test_wifi_rx_admission import admission_source


def source() -> str:
    code = admission_source()
    code = r'''
var onUpper, onFree, onEvent, onTrace: proc()
var delivered, released: seq[int]
var frameMarker: int
proc invoke(hook: var proc()) =
  if hook != nil:
    let action = hook
    hook = nil
    action()
''' + code
    code = code.replace(procedure(code, "rxu_cntrl_frame_handle"), r'''
proc rxu_cntrl_frame_handle(p: pointer): uint32 =
  let index = ((cast[uint](p) - cast[uint](addr rx_swdesc_tab[0])) div sizeof(RxSwTableDescView).uint).int
  frameMarker = index
  delivered.add(index)
  invoke(onUpper)
  doAssert frameMarker == index, "nested RX replaced the active frame context"
  0
''', 1)
    code = code.replace(procedure(code, "rxl_mpdu_free"), r'''
proc rxl_mpdu_free(p: pointer) =
  let index = ((cast[uint](p) - cast[uint](addr rx_swdesc_tab[0])) div sizeof(RxSwTableDescView).uint).int
  released.add(index)
  invoke(onFree)
''', 1)
    code = code.replace(procedure(code, "ke_evt_clear"), r'''
proc ke_evt_clear(mask: uint32) =
  events = events and not mask
  invoke(onEvent)
''', 1)
    code = code.replace(procedure(code, "nimFwTrace2U32"), r'''
proc nimFwTrace2U32(label: string; a, b: uint32) = invoke(onTrace)
''', 1)
    code += r'''
proc setup(count = 6) =
  doAssert not rxlControlActive
  reset(0x0208, 24)
  onUpper = nil
  onFree = nil
  onEvent = nil
  onTrace = nil
  delivered.setLen(0)
  released.setLen(0)
  frameMarker = -1
  for index in 0..<count:
    let header = rxHeaderHwDescAt(index)
    let node = rxSwTableDescAt(index)
    let payload = rxPayloadHwDescAt(index)
    header.mpduLengthBytes = 24
    header.frameLen = 24
    header.hwFlags = 0x02006000'u32 or (12'u32 shl 15)
    header.flags = header.hwFlags or 0x4000
    header.bufferChain = payload
    payload.bufferAddr = pointerAddrU32(addr buffers[index].payloadBytes[0])
    payload.bufferStart = payload.bufferAddr
    payload.frameData = addr buffers[index].payloadBytes[0]
    payload.status = 1
    cast[ptr uint16](payload.frameData)[] = 0x0208
    node.link.next = if index + 1 < count: addr rxSwTableDescAt(index + 1).link else: nil
  env.queue = default(CoList)
  if count != 0:
    env.queue.first = addr rxSwTableDescAt(0).link
    env.queue.last = addr rxSwTableDescAt(count - 1).link
proc nested() =
  let head = env.queue.first
  let beforeDelivered = delivered.len
  let beforeReleased = released.len
  let marker = frameMarker
  let enabled = interrupts
  rxl_cntrl_evt()
  doAssert env.queue.first == head, "nested drain removed a pending frame"
  doAssert delivered.len == beforeDelivered and released.len == beforeReleased
  doAssert frameMarker == marker and interrupts == enabled
proc finish() =
  onUpper = nil
  onFree = nil
  onEvent = nil
  onTrace = nil
  onTick = nil
  onPower = nil
  rxl_cntrl_evt()
  doAssert delivered == @[0, 1, 2, 3, 4, 5]
  doAssert released == delivered and env.queue.first == nil
  doAssert not rxlControlActive and recovered == 0
'''
    return code


@pytest.mark.parametrize("phase", ["event", "trace", "tick", "power", "upper", "free"])
@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_nested_rx_drain(tmp_path: Path, phase: str, mode: str) -> None:
    hook = {"event": "onEvent", "trace": "onTrace", "tick": "onTick",
            "power": "onPower", "upper": "onUpper", "free": "onFree"}[phase]
    checks = f'''
setup()
{hook} = proc() =
  {hook} = nil
  nested()
rxl_cntrl_evt()
doAssert {hook} == nil, "nested RX hook did not run"
doAssert delivered == @[0, 1, 2, 3] and released == delivered
doAssert env.queue.first == addr rxSwTableDescAt(4).link
doAssert (events and 0x100000) != 0 and not rxlControlActive
finish()
'''
    run_program(tmp_path, mode, source() + checks)


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_rx_drain_guard_releases_on_exit(tmp_path: Path, mode: str) -> None:
    checks = r'''
for enabled in [false, true]:
  setup()
  interrupts = enabled
  onEvent = proc() = raise newException(ValueError, "test interruption")
  var raised = false
  try: rxl_cntrl_evt()
  except ValueError: raised = true
  doAssert raised and not rxlControlActive and interrupts == enabled
  doAssert env.queue.first == addr rxSwTableDescAt(0).link
  rxl_cntrl_evt()
  finish()
  doAssert interrupts == enabled
setup(0)
rxl_cntrl_evt()
doAssert not rxlControlActive and delivered.len == 0
setup()
env.processingFlag = 1
rxl_cntrl_evt()
doAssert not rxlControlActive and delivered.len == 0
env.processingFlag = 0
rxl_cntrl_evt()
finish()
'''
    run_program(tmp_path, mode, source() + checks)


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_nested_rx_queue_arrival(tmp_path: Path, mode: str) -> None:
    checks = r'''
setup(1)
onUpper = proc() =
  nested()
  doAssert events == 0
rxl_cntrl_evt()
doAssert delivered == @[0] and released == delivered
doAssert env.queue.first == nil and not rxlControlActive

setup()
let newHead = addr rxSwTableDescAt(1).link
let newTail = addr rxSwTableDescAt(5).link
rxSwTableDescAt(0).link.next = nil
env.queue.last = addr rxSwTableDescAt(0).link
onUpper = proc() =
  doAssert env.queue.first == nil
  env.queue = CoList(first: newHead, last: newTail)
  nested()
  doAssert (events and 0x100000) != 0
rxl_cntrl_evt()
doAssert delivered == @[0, 1, 2, 3] and released == delivered
doAssert env.queue.first == addr rxSwTableDescAt(4).link
finish()
'''
    run_program(tmp_path, mode, source() + checks)
