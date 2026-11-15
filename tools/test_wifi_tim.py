"""Exercise production TIM updates, descriptor chains, and message ownership."""

from pathlib import Path
import re
import shutil
import subprocess

import pytest

from test_wifi_ap_teardown import FW, ROOT, procedure


PLATFORM = r'''
import bl808/wifi/fw_constants/limits_events
const
  MAX_VIFS = 2
  TASK_MM = 0'u8
  KeMsgNoFree = 1.cint
  VIF_TYPE_AP = 2'u8
type
  Header = object
    next: ptr Header
    id: uint16
    destId, srcId: uint8
    paramLen: uint32
  KeMsgHdr = Header
  CoListHdr = Header
  CoList = object
    first, last: ptr Header
  Env = object
    templatePtr: pointer
    pendingCount: uint32
    transmitRequested, active, deferredChange: uint8
    timQueue: CoList
  Frame = object
    callback, callbackArg: pointer
  HwDesc = object
    retryLimitControl, controlFlags, status: uint32
  Vif = object
    vifIdx, vifType, beaconEnabled: uint8
    timLength, timCount: uint16
    timMin, timMax, timCountdown, timFlags: uint8
    beaconTxDesc: pointer
    frame: Frame
  BitmapGuard = object
    before: array[16, uint8]
    bytes: array[BITMAP_SIZE, uint8]
    after: array[16, uint8]
var
  env: Env
  mmBcnStopping: bool
  mmBcnGeneration: uint32
  rxVifEpochs: array[2, uint32]
  vifs: array[2, Vif]
  hw: array[2, HwDesc]
  bitmap: BitmapGuard
  txl_tim_ie_pool: array[6, uint8]
  txl_tim_desc: array[sizeof(TimDescView), uint8]
  txl_bcn_end_desc: array[sizeof(BeaconEndDescView), uint8]
  txl_bcn_pool: array[860, uint8]
  txl_bcn_hwdesc_pool: array[72, uint8]
  txl_bcn_hwdesc_cfms: array[20, uint8]
  txl_bcn_buf_ctrl: array[60, uint8]
  allocated: seq[pointer]
  acknowledged: seq[uint8]
  frees, assertions, templateUpdates: int
  interrupts = true
template txl_tim_bitmap_pool: untyped = bitmap.bytes
proc irqSave(): uint32 =
  result = if interrupts: 8'u32 else: 0'u32
  interrupts = false
proc irqRestore(saved: uint32) = interrupts = (saved and 8) != 0
# The bitmap matrix is independent of message-session identity.
proc mmTimMessageCurrent(header: ptr KeMsgHdr): bool = true
proc calloc(count, size: csize_t): pointer {.importc, header: "<stdlib.h>".}
proc free(p: pointer) {.importc, header: "<stdlib.h>".}
proc bcnEnvView(): ptr Env = addr env
proc vifChannelForIdx(i: uint8): ptr Vif = addr vifs[i]
proc vifChannelAt(p: pointer): ptr Vif = cast[ptr Vif](p)
proc vifApBeaconFrameDesc(v: ptr Vif): ptr Frame = addr v.frame
proc hostTxHwDescAt(p: pointer): ptr HwDesc = cast[ptr HwDesc](p)
proc timDescView(): ptr TimDescView = cast[ptr TimDescView](addr txl_tim_desc[0])
proc timIeAt(p: pointer): ptr TimIeView = cast[ptr TimIeView](p)
proc beaconEndDesc(): ptr BeaconEndDescView = cast[ptr BeaconEndDescView](addr txl_bcn_end_desc[0])
proc c_memset(p: pointer; value: cint; n: csize_t): pointer =
  doAssert value == 0
  zeroMem(p, n.int)
  p
proc txl_frame_init_desc(frame, pool, desc, ctrl: pointer) = discard
proc assert_err(file, expression: cstring; line: cint) = inc assertions
proc keMsgHdrFromPayload(p: pointer): ptr Header =
  cast[ptr Header](cast[uint](p) - sizeof(Header).uint)
proc keMsgPayload(h: ptr Header): pointer = cast[pointer](cast[uint](h) + sizeof(Header).uint)
proc newMessage(aid: uint16; setFlag, vif: uint8; size = 4'u32; src = 9'u8): pointer =
  let h = cast[ptr Header](calloc(1, (sizeof(Header) + max(4, size.int)).csize_t))
  doAssert h != nil
  h[] = Header(id: 0x2F, srcId: src, paramLen: size)
  result = keMsgPayload(h)
  cast[ptr MmTimUpdatePayload](result)[] = MmTimUpdatePayload(aid: aid, setFlag: setFlag, vifIdx: vif)
  allocated.add(result)
proc ke_msg_send_basic(id: uint16; dst, src: uint8) =
  doAssert id == 0x30 and src == TASK_MM
  acknowledged.add(dst)
proc ke_msg_free(p: pointer) =
  let payload = keMsgPayload(cast[ptr Header](p))
  let index = allocated.find(payload)
  doAssert index >= 0, "TIM request freed twice or without ownership"
  allocated.delete(index)
  inc frees
  free(p)
proc mm_bcn_update(p: pointer): pointer =
  doAssert p == env.templatePtr
  inc templateUpdates
  env.templatePtr = nil
  env.deferredChange = 0
  nil
proc mmBcnApplyUpdate(request: pointer; callbackIrq: uint32): pointer =
  mm_bcn_update(request)
proc mm_bcn_transmitted*(vifEntry: pointer) {.exportc, cdecl.}
proc txlFrameCallbackCurrent(): bool = true
proc mm_tim_update_proceed*(param: pointer) {.exportc, cdecl, noinline.}
'''

HELPERS = r'''
proc guard() =
  for value in bitmap.before: doAssert value == 0xA5, "bitmap underrun"
  for value in bitmap.after: doAssert value == 0xA5, "bitmap overrun"
proc reset(vif = 0'u8) =
  doAssert allocated.len == 0
  env = default(Env)
  vifs = default(typeof(vifs))
  hw = default(typeof(hw))
  for value in bitmap.before.mitems: value = 0xA5
  for value in bitmap.after.mitems: value = 0xA5
  for value in bitmap.bytes.mitems: value = 0xA5
  for value in txl_tim_desc.mitems: value = 0xA5
  frees = 0
  assertions = 0
  templateUpdates = 0
  acknowledged.setLen(0)
  for i in 0 ..< vifs.len:
    vifs[i].vifIdx = i.uint8
    vifs[i].beaconTxDesc = addr hw[i]
  mm_bcn_init_vif(addr vifs[vif])
  vifs[vif].vifType = VIF_TYPE_AP
  vifs[vif].beaconEnabled = 1
proc dispatch(p: pointer) =
  let handler = cast[proc(p: pointer): cint {.cdecl.}](mm_tim_update_req_handler)
  doAssert handler(p) == KeMsgNoFree, "TIM handler must transfer request ownership"
proc update(aid: uint16; setFlag: uint8; vif = 0'u8) =
  let before = frees
  dispatch(newMessage(aid, setFlag, vif))
  doAssert frees == before + 1 and allocated.len == 0
proc serializedTim(): seq[uint8] =
  let d = timDescView()
  doAssert d.magic == 0xCAFEFADE'u32
  doAssert d.payloadStart == addr txl_tim_ie_pool[0]
  let start = cast[uint](d.payloadStart)
  let finish = cast[uint](d.payloadEnd)
  doAssert finish >= start and finish - start < txl_tim_ie_pool.len.uint
  for i in 0'u .. finish - start: result.add(cast[ptr uint8](start + i)[])
  if d.next == addr d.bitmapMagic:
    doAssert d.bitmapMagic == 0xCAFEFADE'u32
    doAssert d.bitmapNext == addr txl_bcn_end_desc[0]
    let first = cast[uint](d.bitmapStart)
    let last = cast[uint](d.bitmapEnd)
    let base = cast[uint](addr bitmap.bytes[0])
    doAssert first >= base and last >= first and last < base + 251
    for i in first .. last: result.add(cast[ptr uint8](i)[])
  else:
    doAssert d.next == addr txl_bcn_end_desc[0], "TIM descriptor links into data"
  doAssert result.len == result[1].int + 2
proc verify(model: array[2008, bool]; vif: uint8) =
  var count = 0
  var first = 251
  var last = 0
  for aid in 1 .. 2007:
    if model[aid]:
      inc count
      first = min(first, aid shr 3)
      last = max(last, aid shr 3)
  let v = addr vifs[vif]
  doAssert v.timCount == count.uint16
  let bytes = serializedTim()
  doAssert bytes[0] == 5 and bytes[2] == 0 and bytes[3] == 1
  if count == 0:
    doAssert v.timMin == 0xFF and v.timMax == 0, "wrong empty bitmap range"
    doAssert v.timLength == 6
    doAssert bytes == @[5'u8, 4, 0, 1, 0, 0], "empty TIM advertises phantom traffic"
  else:
    first = first and 0xFE
    doAssert v.timMin == first.uint8 and v.timMax == last.uint8
    doAssert v.timLength == (last - first + 6).uint16
    doAssert bytes[4] == first.uint8 and bytes.len == v.timLength.int
    for aid in 1 .. 2007:
      let index = (aid shr 3) - first
      let inTim = index >= 0 and index + 5 < bytes.len and
        (bytes[index + 5] and (1'u8 shl (aid and 7))) != 0
      doAssert inTim == model[aid], "serialized TIM differs from queued AIDs"
  doAssert v.timFlags == model[0].uint8
  guard()
'''


def source() -> str:
    layout = (FW / "layout_types.nim").read_text()
    types = "type\n"
    for name in ["MacIeView", "TimIeView", "TimDescView", "BeaconEndDescView", "MmTimUpdatePayload"]:
        body = layout.split("  " + name + " ", 1)[1].split("\n\n  ", 1)[0]
        types += "  " + name + " " + body + "\n"
    storage = (FW / "global_state/storage.nim").read_text()
    size = re.search(r"txl_tim_bitmap_pool.*?: array\[(\d+), uint8\]", storage)
    assert size
    platform = PLATFORM.replace("BITMAP_SIZE", size.group(1))
    kernel = (FW / "kernel_mac_channel.nim").read_text()
    tasks = (FW / "task_handlers.nim").read_text()
    bodies = "".join(procedure(kernel, name) for name in [
        "co_list_init", "co_list_push_back", "co_list_pop_front", "mmBeaconPoolIdle", "mmBcnOwnerCurrent", "mm_bcn_init_vif",
        "mm_tim_update", "mm_bcn_transmitted",
    ])
    bodies += procedure(tasks, "mm_tim_update_req_handler")
    bodies += procedure(tasks, "mm_tim_update_proceed")
    return types + "const MmTimUpdatePayloadSize = 4'u32\n" + platform + bodies + HELPERS


def run(tmp_path: Path, checks: str, mode: str) -> None:
    nim = shutil.which("nim")
    if nim is None:
        pytest.skip("nim is not installed")
    path = tmp_path / "tim.nim"
    path.write_text(source() + checks)
    options = {"checked": ["--checks:on"], "release": ["-d:release"],
               "danger": ["-d:danger"]}[mode]
    result = subprocess.run(
        [nim, "c", "-r", "--skipParentCfg:on", "--skipProjCfg:on", "--skipUserCfg:on",
         *options, f"--path:{ROOT / 'src'}", f"--nimcache:{tmp_path / 'cache'}",
         f"-o:{tmp_path / 'tim'}", str(path)],
        cwd=ROOT, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
    )
    assert result.returncode == 0, result.stdout


@pytest.mark.parametrize("mode", ["checked", "release", "danger"])
def test_tim_reinitialization_rejects_busy_pool(tmp_path: Path, mode: str) -> None:
    checks = r'''
reset()
let initialized = mmBcnGeneration
update(17, 1)
let beforeBitmap = bitmap.bytes
let beforeDescriptor = timDescView()[]
env.pendingCount = 1
mm_bcn_init_vif(addr vifs[1])
doAssert assertions == 1 and bitmap.bytes == beforeBitmap
doAssert mmBcnGeneration == initialized
doAssert timDescView()[] == beforeDescriptor
env.pendingCount = 0
env.templatePtr = cast[pointer](0x1234)
mm_bcn_init_vif(addr vifs[1])
doAssert assertions == 2 and bitmap.bytes == beforeBitmap
doAssert mmBcnGeneration == initialized
env.templatePtr = nil
mm_bcn_init_vif(nil)
doAssert mmBcnGeneration == initialized
mm_bcn_init_vif(addr vifs[0])
doAssert mmBcnGeneration == initialized + 1
mmBcnGeneration = high(uint32)
mm_bcn_init_vif(addr vifs[0])
doAssert mmBcnGeneration == 0
var model: array[2008, bool]
verify(model, 0)
'''
    run(tmp_path, checks, mode)


@pytest.mark.parametrize("mode", ["checked", "release", "danger"])
def test_tim_initialization_and_bitmap_write_boundaries(tmp_path: Path, mode: str) -> None:
    run(tmp_path, r'''
for vif in 0'u8 .. 1:
  reset(vif)
  guard()
  doAssert bitmap.bytes.len == 252, "vendor clears 252 bytes"
  for value in bitmap.bytes: doAssert value == 0
  var model: array[2008, bool]
  verify(model, vif)
  doAssert timDescView().bitmapEnd == addr bitmap.bytes[0]
  doAssert vifs[vif].frame.callback == cast[pointer](mm_bcn_transmitted)
  doAssert vifs[vif].frame.callbackArg == addr vifs[vif]
''', mode)


@pytest.mark.parametrize("mode", ["checked", "release", "danger"])
def test_tim_aid_state_machine_and_descriptor_bytes(tmp_path: Path, mode: str) -> None:
    run(tmp_path, r'''
for vif in 0'u8 .. 1:
  reset(vif)
  var model: array[2008, bool]
  for aid in 1 .. 2007:
    update(aid.uint16, 1, vif)
    model[aid] = true
    verify(model, vif)
    let descriptor = timDescView()[]
    update(aid.uint16, 255, vif)
    doAssert timDescView()[] == descriptor
    update(aid.uint16, 0, vif)
    model[aid] = false
    verify(model, vif)
    update(aid.uint16, 0, vif)
  # Removing the low/high boundary must shorten a nonempty bitmap.
  for aid in [1, 16, 25, 80, 1999, 2007]:
    update(aid.uint16, 1, vif)
    model[aid] = true
  for aid in [1, 2007, 1999, 16, 25, 80]:
    update(aid.uint16, 0, vif)
    model[aid] = false
    verify(model, vif)
  for aid in 1 .. 2007:
    update(aid.uint16, 1, vif)
    model[aid] = true
  verify(model, vif)
  for aid in countdown(2007, 1):
    update(aid.uint16, 0, vif)
    model[aid] = false
    verify(model, vif)
  var random = 0xBAD5EED'u32
  for iteration in 0 ..< 4000:
    random = random * 1664525'u32 + 1013904223'u32
    let aid = (random mod 2008).int
    let value = (random shr 24) and 1
    update(aid.uint16, value.uint8, vif)
    model[aid] = value != 0
    verify(model, vif)
''', mode)


@pytest.mark.parametrize("mode", ["checked", "release", "danger"])
def test_tim_deferred_ownership_and_malformed_requests(tmp_path: Path, mode: str) -> None:
    run(tmp_path, r'''
reset()
var model: array[2008, bool]
env.pendingCount = 2
let first = newMessage(1, 1, 0, src = 2)
let second = newMessage(2007, 1, 0, src = 3)
let third = newMessage(1, 0, 0, src = 4)
dispatch(first)
dispatch(second)
dispatch(third)
doAssert env.timQueue.first == keMsgHdrFromPayload(first)
doAssert env.timQueue.last == keMsgHdrFromPayload(third)
doAssert frees == 0 and acknowledged.len == 0 and allocated.len == 3
verify(model, 0)
mm_bcn_transmitted(addr vifs[0])
doAssert env.pendingCount == 1 and frees == 0
env.deferredChange = 1
env.templatePtr = cast[pointer](1234)
mm_bcn_transmitted(addr vifs[0])
model[2007] = true
verify(model, 0)
doAssert env.pendingCount == 0 and env.timQueue.first == nil
doAssert templateUpdates == 1 and allocated.len == 0 and frees == 3
doAssert acknowledged == @[2'u8, 3, 4], "deferred TIM updates lost FIFO order"
# A duplicate completion must not wrap the count or process unrelated work.
mm_bcn_transmitted(addr vifs[0])
doAssert env.pendingCount == 0 and assertions == 1 and frees == 3
for aid in [2008'u16, 2047, 2048, 65535]:
  update(aid, 1)
  verify(model, 0)
for vif in [2'u8, 255]:
  update(1, 1, vif)
  verify(model, 0)
for size in 0'u32 .. 3:
  let before = frees
  dispatch(newMessage(1, 1, 0, size))
  doAssert frees == before + 1
  verify(model, 0)
let before = frees
mm_tim_update(nil)
mm_tim_update_proceed(nil)
doAssert frees == before and allocated.len == 0
# A new batch remains usable after the old queue has drained.
env.pendingCount = 1
dispatch(newMessage(2007, 0, 0))
mm_bcn_transmitted(addr vifs[0])
model[2007] = false
verify(model, 0)
doAssert allocated.len == 0
''', mode)
