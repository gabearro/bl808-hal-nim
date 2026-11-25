"""Exercise real TIM allocation, publication, and deferred consumption lifetimes."""

from pathlib import Path
import re
import shutil
import subprocess

import pytest

from test_wifi_disconnect_tx import procedure
from test_wifi_tim import source as bitmap_source

ROOT = Path(__file__).resolve().parents[1]
FW = ROOT / "src/bl808/wifi/fw"

PLATFORM = r"""
const
  TASK_MAX = 11'u8
  TASK_LAST_EMB = 8'u8
  TASK_ME = 3'u8
  MM_TIM_UPDATE_REQ = 47'u16
  KE_EVT_KE_MESSAGE = 0x08000000'u32
  KeMsgHdrSize = sizeof(KeMsgHdr).uint
  KeMsgTailSlack = 4'u32
type
  Sta = object
    valid, instNbr, trafficFlags: uint8
    aid: uint16
var
  stas: array[7, Sta]
  stationEpochs: array[5, uint32]
  mmTimIdentities: ptr MmTimIdentityNode
  keMsgQueueSent: CoList
  events: uint32
  allocations: int
  failAllocation: bool
  cached: pointer
  cachedSize: uint32
  allocationSize: uint32
proc inject(point: string)
proc staInfoForIdx(i: uint8): ptr Sta = addr stas[i]
proc staDeleteEpoch(i: uint8): uint32 =
  if i < 5: stationEpochs[i] else: 0
proc heapAlloc(size: uint32): pointer {.cdecl.} =
  inc allocations
  allocationSize = size
  inject("allocation")
  if failAllocation: return nil
  if cached != nil and cachedSize >= size:
    result = cached
    cached = nil
  else:
    result = calloc(1, size.csize_t)
  doAssert result != nil
  let bytes = cast[ptr UncheckedArray[uint8]](result)
  for i in 0 ..< size.int: bytes[i] = 0xA5
  allocated.add(keMsgPayload(cast[ptr KeMsgHdr](result)))
proc heapFree(p: pointer) {.cdecl.} =
  var node = mmTimIdentities
  while node != nil:
    doAssert node.message != p, "freed message retains lifetime metadata"
    node = node.next
  let index = allocated.find(keMsgPayload(cast[ptr KeMsgHdr](p)))
  doAssert index >= 0, "message freed twice"
  allocated.delete(index)
  inc frees
  if cached == nil:
    cached = p
    cachedSize = allocationSize
  else: free(p)
  inject("free")
proc blOpsFunc(offset: int): pointer =
  case offset
  of 0xB8: cast[pointer](heapAlloc)
  of 0xBC: cast[pointer](heapFree)
  else: nil
template platformFree(p: pointer) = heapFree(p)
proc rxMgtForget(p: pointer) = discard
proc mmConnLossForget(p: pointer) = discard
proc smCleanupForget(p: pointer) = discard
proc smBssForget(p: pointer) = discard
proc smActivationForget(p: pointer) = discard
proc chanSwitchForget(p: pointer): bool = false
proc scanDwellForget(p: pointer) = discard
proc smRspTimerForget(p: pointer) = discard
proc smDeferredForget(p: pointer) = discard
proc smAbortStorageLength(id: uint16; destination: uint8; length: uint32): uint32 = length
proc smAbortRegister(header: ptr KeMsgHdr) = discard
proc smAbortForget(header: pointer) = discard
proc mmEdcaForget(header: pointer) = discard
proc mmConfigForgetIdleOwner(header: pointer): bool = false
proc smAbortCaptureMessage(header: ptr KeMsgHdr) = discard
proc chanUpdateStorageLength(id: uint16; destination: uint8; length: uint32): uint32 = length
proc chanUpdateRegister(header: ptr KeMsgHdr) = discard
proc chanUpdateCaptureMessage(header: ptr KeMsgHdr) = discard
proc chanUpdateForget(header: pointer) = discard
proc chanBcnRequestForget(header: pointer) = discard
proc keMsgExternalPayload(p: pointer): pointer = p
proc bl_rx_e2a_handler(p: pointer) = discard
proc nimFwTrace(s: string) = discard
proc nimFwTrace2U32(s: string; a, b: uint32) =
  if s == "[WIFI-NIMFW] ke_msg_send internal ":
    doAssert a == 47 and b == 0
    inject("trace")
proc ke_evt_set(bits: uint32) =
  events = events or bits
  inject("event")
proc ke_msg_alloc*(id: uint16; destId, srcId: uint8; paramLen: uint32): pointer {.exportc, cdecl.}
"""

CHECKS = r"""
var
  trigger: string
  action: int
  fired: bool
  replacement: pointer
  oldAddress: pointer

proc newMessage(aid: uint16; setFlag, vif: uint8; size = 4'u32; src = 9'u8): pointer =
  result = ke_msg_alloc(47, 0, src, size)
  doAssert result != nil
  if size >= 4:
    cast[ptr MmTimUpdatePayload](result)[] = MmTimUpdatePayload(
      aid: aid, setFlag: setFlag, vifIdx: vif)

proc send(aid: uint16; value: uint8; vif = 0'u8; size = 4'u32): pointer =
  result = newMessage(aid, value, vif, size)
  doAssert keMsgHdrFromPayload(result).paramLen == size, "wire length includes private metadata"
  let bytes = cast[ptr UncheckedArray[uint8]](result)
  for i in size.int ..< size.int + 4:
    doAssert bytes[i] == 0xA5, "private metadata overlaps rounded IPC copy slack"
  ke_msg_send(result)

proc drainSent() =
  while keMsgQueueSent.first != nil:
    let header = co_list_pop_front(addr keMsgQueueSent)
    dispatch(keMsgPayload(cast[ptr KeMsgHdr](header)))
  events = events and not KE_EVT_KE_MESSAGE

proc drainBeacon() =
  env.pendingCount = 0
  while env.timQueue.first != nil:
    let header = co_list_pop_front(addr env.timQueue)
    mm_tim_update_proceed(keMsgPayload(cast[ptr KeMsgHdr](header)))

proc inject(point: string) =
  if point != trigger or fired: return
  fired = true
  if point == "allocation":
    inc stationEpochs[2]
    return
  if point == "free":
    doAssert acknowledged == @[9'u8], "TIM confirmation followed request free"
    replacement = newMessage(17, 1, 0, src = 6)
    doAssert cast[pointer](keMsgHdrFromPayload(replacement)) == oldAddress
    ke_msg_send(replacement)
    return
  doAssert keMsgQueueSent.first != nil, "logging/event callback ran before publication"
  if action == 1: inc stationEpochs[2]
  let old = cast[pointer](keMsgQueueSent.first)
  drainSent()
  if action == 2:
    replacement = send(17, 1)
    doAssert cast[pointer](keMsgHdrFromPayload(replacement)) == old,
      "test did not exercise identical message-address reuse"

proc setup(irq = true) =
  doAssert allocated.len == 0 and mmTimIdentities == nil
  doAssert keMsgQueueSent.first == nil and env.timQueue.first == nil
  reset()
  stas = default(typeof(stas))
  stas[2] = Sta(valid: 1, instNbr: 0, aid: 42)
  stationEpochs = default(typeof(stationEpochs))
  rxVifEpochs = default(typeof(rxVifEpochs))
  trigger = ""
  fired = false
  replacement = nil
  events = 0
  allocations = 0
  failAllocation = false
  interrupts = irq

proc changeOwner(change: int; message: pointer) =
  case change
  of 0: inc stationEpochs[2]
  of 1: inc rxVifEpochs[0]
  of 2:
    stas[2].valid = 0
    stas[3] = Sta(valid: 1, instNbr: 0, aid: 42)
  of 3: stas[2].valid = 0
  of 4: inc stationEpochs[1]
  of 5: inc rxVifEpochs[1]
  of 6: cast[ptr MmTimUpdatePayload](message).aid = 17
  of 7: cast[ptr MmTimUpdatePayload](message).vifIdx = 1
  of 8: cast[ptr MmTimUpdatePayload](message).setFlag = 7
  of 9:
    inc stationEpochs[2]
    mmTimCaptureMessage(keMsgHdrFromPayload(message))
  else: discard

for irq in [false, true]:
  for beaconDeferred in [false, true]:
    for value in [0'u8, 1]:
      for change in 0 .. 10:
        setup(irq)
        # Seed the bitmap for clear tests, using a fully published request.
        if value == 0:
          discard send(42, 1)
          drainSent()
        let beforeFrees = frees
        let beforeAck = acknowledged.len
        let message = send(42, value)
        if beaconDeferred:
          env.pendingCount = 1
          drainSent()
          doAssert env.timQueue.first == keMsgHdrFromPayload(message)
        changeOwner(change, message)
        if beaconDeferred: drainBeacon()
        else: drainSent()
        doAssert frees == beforeFrees + 1 and acknowledged.len == beforeAck + 1
        doAssert allocated.len == 0 and mmTimIdentities == nil
        doAssert interrupts == irq
        let allowed = change in [4, 5, 10] or (change == 3 and value == 0)
        let expected = if allowed: value != 0 else: value == 0
        doAssert vifs[0].timCount == expected.uint16,
          "stale kernel/beacon request changed a replacement peer's TIM"
        doAssert bitmap.bytes[42 shr 3] == (if expected: 4'u8 else: 0'u8)

  # Already-stale kernel work must not consume space in the beacon queue.
  setup(irq)
  env.pendingCount = 1
  discard send(42, 1)
  inc stationEpochs[2]
  drainSent()
  doAssert frees == 1 and env.timQueue.first == nil and mmTimIdentities == nil
  env.pendingCount = 0

  # Confirmation is published before free can reenter allocation.
  setup(irq)
  discard send(42, 1)
  let original = co_list_pop_front(addr keMsgQueueSent)
  oldAddress = cast[pointer](original)
  trigger = "free"
  dispatch(keMsgPayload(cast[ptr KeMsgHdr](original)))
  doAssert fired and acknowledged == @[9'u8]
  doAssert allocated.len == 1 and mmTimIdentities != nil
  drainSent()
  doAssert acknowledged == @[9'u8, 6'u8] and mmTimIdentities == nil

  for point in ["event", "trace"]:
    for callbackAction in 0 .. 2:
      setup(irq)
      trigger = point
      action = callbackAction
      discard send(42, 1)
      doAssert fired and interrupts == irq
      if callbackAction == 2:
        doAssert allocated.len == 1 and mmTimIdentities != nil
        drainSent()
        doAssert vifs[0].timCount == 2
      else: doAssert vifs[0].timCount == (callbackAction == 0).uint16
      doAssert allocated.len == 0 and mmTimIdentities == nil
      doAssert events == 0

  # Multicast is VIF-bound; previously unoccupied AIDs cannot acquire a new peer.
  for aid in [0'u16, 2007]:
    for changed in [false, true]:
      setup(irq)
      discard send(aid, 1)
      if changed:
        if aid == 0: inc rxVifEpochs[0]
        else: stas[1] = Sta(valid: 1, instNbr: 0, aid: aid)
      drainSent()
      doAssert (if aid == 0: vifs[0].timFlags.uint16 else: vifs[0].timCount) == (not changed).uint16
      doAssert mmTimIdentities == nil

  for size in 0'u32 .. 3:
    setup(irq)
    discard send(42, 1, size = size)
    drainSent()
    doAssert frees == 1 and acknowledged.len == 1 and vifs[0].timCount == 0
  for aid in [2008'u16, 65535]:
    setup(irq)
    discard send(aid, 1)
    drainSent()
    doAssert frees == 1 and vifs[0].timCount == 0 and mmTimIdentities == nil
  setup(irq)
  discard send(42, 1, 255)
  drainSent()
  doAssert frees == 1 and vifs[0].timCount == 0 and mmTimIdentities == nil

  # The actual AP producer can abandon an allocation after its peer is replaced.
  for invalidated in [false, true]:
    setup(irq)
    stas[2].trafficFlags = 2
    if invalidated: trigger = "allocation"
    let saved = irqSave()
    let identity = apmPsCapture(addr stas[2])
    apmPsTimRequest(identity, 2, 1)
    irqRestore(saved)
    doAssert interrupts == irq
    if invalidated:
      doAssert fired and frees == 1 and keMsgQueueSent.first == nil
    else:
      doAssert keMsgQueueSent.first != nil
      drainSent()
      doAssert vifs[0].timCount == 1
    doAssert allocated.len == 0 and mmTimIdentities == nil

  setup(irq)
  let unpublished = newMessage(42, 1, 0)
  dispatch(unpublished)
  doAssert frees == 1 and vifs[0].timCount == 0, "unpublished message accepted"
  # No fixed registry limit: every live request retains its own metadata.
  setup(irq)
  for i in 0 ..< 128: discard send(42, (i and 1).uint8)
  var node = mmTimIdentities
  var count = 0
  while node != nil:
    inc count
    node = node.next
  doAssert count == 128
  drainSent()
  doAssert frees == 128 and acknowledged.len == 128 and vifs[0].timCount == 1
  doAssert mmTimIdentities == nil and interrupts == irq

  # External forwarding uses a different free path but must unlink metadata.
  setup(irq)
  let external = newMessage(42, 1, 0)
  keMsgHdrFromPayload(external).destId = 9
  ke_msg_send(external)
  doAssert mmTimIdentities == nil and frees == 1

  setup(irq)
  failAllocation = true
  doAssert ke_msg_try_alloc(47, 0, 9, 4) == nil and mmTimIdentities == nil
  for length in [high(uint32), high(uint32) - 3, high(uint32) - 32]:
    let before = allocations
    doAssert ke_msg_try_alloc(47, 0, 9, length) == nil
    doAssert allocations == before
  doAssert interrupts == irq
if cached != nil: free(cached)
"""


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
@pytest.mark.parametrize("mutation", [None, "vif", "station", "beacon", "kernel", "recapture", "forget", "publication", "payload", "free_before_send"])
def test_tim_message_lifetime(tmp_path: Path, mode: str, mutation: str | None) -> None:
    nim = shutil.which("nim")
    if nim is None:
        pytest.skip("Nim is required")
    kernel = (FW / "kernel_mac_channel.nim").read_text()
    layout = (FW / "layout_types.nim").read_text()
    node = "type\n  ApmPsSession = object" + layout.split(
        "  ApmPsSession = object", 1)[1].split("\n  StaQueueIdentity", 1)[0]
    base = bitmap_source()
    for name, declaration in [
        ("newMessage", "proc newMessage(aid: uint16; setFlag, vif: uint8; size = 4'u32; src = 9'u8): pointer\n"),
        ("ke_msg_free", "proc ke_msg_free*(param: pointer) {.exportc, cdecl.}\n"),
        ("mmTimMessageCurrent", "proc mmTimMessageCurrent(header: ptr KeMsgHdr): bool\n"),
    ]:
        base = base.replace(procedure(base, name), declaration)
    insertion = base.index("proc mm_bcn_update")
    base = base[:insertion] + node + PLATFORM + base[insertion:]
    functions = "".join(procedure(kernel, name) for name in [
        "mmTimAllocationSize", "mmTimRegisterAllocation", "mmTimFindStation",
        "mmTimCaptureMessage", "mmTimMessageCurrent", "mmTimForget",
        "ke_msg_try_alloc", "ke_msg_alloc", "ke_msg_send", "ke_msg_free", "ke_msg_free_payload",
    ])
    apm = (FW / "scan_station_ap_me.nim").read_text()
    functions += "".join(procedure(apm, name) for name in [
        "apmPsCapture", "apmPsSessionCurrent", "apmPsTimRequest",
    ])
    if mutation == "vif":
        functions = functions.replace("rxVifEpochs[node.vif] != node.vifEpoch", "false")
    elif mutation == "station":
        functions = functions.replace("station == node.station and staDeleteEpoch(station) == node.stationEpoch", "true")
    elif mutation == "beacon":
        base = base.replace("  if not mmTimMessageCurrent(msgHdr):\n    return\n", "")
    elif mutation == "kernel":
        base = base.replace("mmBcnStopping or not mmTimMessageCurrent(keMsgHdrFromPayload(msgBody))", "mmBcnStopping")
    elif mutation == "recapture":
        functions = functions.replace("      if node.captured:\n        return\n", "")
    elif mutation == "forget":
        functions = functions.replace("  mmTimForget(param)\n", "")
    elif mutation == "publication":
        line = '    nimFwTrace2U32("[WIFI-NIMFW] ke_msg_send internal ", messageId, destTask.uint32)\n'
        assert line in functions
        functions = functions.replace(line, "").replace("    block:\n", line + "    block:\n")
    elif mutation == "payload":
        functions = functions.replace("      if req.vifIdx != node.vif or req.aid != node.aid or req.setFlag != node.setFlag:", "      if false:")
    elif mutation == "free_before_send":
        old = "    ke_msg_send_basic(0x30, sender, TASK_MM)\n    ke_msg_free(msgHdr)"
        assert old in base
        base = base.replace("  let sender = msgHdr.srcId\n", "").replace(
            old,
            "    ke_msg_free(msgHdr)\n    ke_msg_send_basic(0x30, msgHdr.srcId, TASK_MM)")
    source = tmp_path / "tim_lifetime.nim"
    source.write_text(base + functions + CHECKS)
    flags = {"checked": [], "release": ["-d:release", "--assertions:on"],
             "asan": ["--cc:clang", "--passC:-fsanitize=address", "--passL:-fsanitize=address"]}
    result = subprocess.run([nim, "c", "-r", "--skipParentCfg:on", "--skipProjCfg:on", "--skipUserCfg:on",
        f"--path:{ROOT / 'src'}", f"--nimcache:{tmp_path / 'cache'}", f"-o:{tmp_path / 'test'}",
        *flags[mode], str(source)], cwd=ROOT, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=120)
    if mutation is None:
        assert result.returncode == 0, result.stdout
    else:
        assert result.returncode != 0 and "AssertionDefect" in result.stdout, result.stdout
