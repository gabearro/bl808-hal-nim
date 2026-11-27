"""Check RX DMA initialization and recycling against the vendor field writes."""

from pathlib import Path

import pytest

from test_wifi_auth_frames import layouts
from test_wifi_disconnect_tx import FW, procedure
from test_wifi_message_allocation import run_program


PLATFORM = r'''
type CoList = object
  first, last: pointer
'''

SUPPORT = r'''
var
  headers: array[WifiRxRingSlots, RxHeaderHwDescView]
  payloads: array[WifiRxRingSlots, RxPayloadHwDescView]
  buffers: array[WifiRxRingSlots, RxPayloadBufferView]
  software: array[WifiRxRingSlots, RxSwTableDescView]
  lower: RxlCntrlEnvView
  hardware: RxHwDescEnvView
  triggers: seq[uint32]
  forgotten: seq[int]
  hdSubmitted, pdSubmitted, hdHead, pdHead: uint32
  irqLevel = 8'u32
  rxInitializationEpoch: uint32
  enters, exits, errors: int
  txControlState: tuple[resetInProgress: uint8]
  resetEvents: uint32
  disabledMacIrqs: int
proc pointerAddrU32(p: pointer): uint32 = cast[uint32](cast[uint](p))
proc rxHeaderHwDescAt(i: int): ptr RxHeaderHwDescView = addr headers[i]
proc rxHeaderHwDescView(p: pointer): ptr RxHeaderHwDescView =
  cast[ptr RxHeaderHwDescView](p)
proc rxPayloadHwDescAt(i: int): ptr RxPayloadHwDescView = addr payloads[i]
proc rxPayloadBufferAt(i: int): ptr RxPayloadBufferView = addr buffers[i]
proc rxSwTableDescAt(i: int): ptr RxSwTableDescView = addr software[i]
proc rxDmaProgressDescAt(p: pointer): ptr RxDmaProgressDescView =
  cast[ptr RxDmaProgressDescView](p)
proc rxlCntrlEnvView(): ptr RxlCntrlEnvView = addr lower
proc rxHwDescEnvView(): ptr RxHwDescEnvView = addr hardware
proc rxForgetStation(p: pointer) =
  for i in 0 ..< headers.len:
    if p == addr headers[i]:
      forgotten.add(i)
      return
  doAssert false, "unexpected header identity"
proc irqSave(): uint32 =
  result = irqLevel
  irqLevel = 0
proc irqRestore(saved: uint32) = irqLevel = saved
proc txControlEnv(): ptr typeof(txControlState) = addr txControlState
proc hal_machw_disable_int() =
  doAssert irqLevel == 0
  inc disabledMacIrqs
proc ke_evt_set(mask: uint32) =
  doAssert irqLevel == 0 and mask == 0x80000000'u32
  resetEvents = resetEvents or mask
proc enter(): uint32 {.cdecl.} =
  inc enters
  result = irqLevel
  irqLevel = 0
proc leave(saved: uint32) {.cdecl.} =
  inc exits
  irqLevel = saved
proc blOpsFunc(slot: int): pointer =
  case slot
  of 20: cast[pointer](enter)
  of 24: cast[pointer](leave)
  else: nil
proc machwRxHwHdHead(): uint32 = hdHead
proc machwRxHwPdHead(): uint32 = pdHead
proc machwRxSetHdSubmittedHead(value: uint32) = hdSubmitted = value
proc machwRxSetPdSubmittedHead(value: uint32) = pdSubmitted = value
proc machwRxDmaTrigger(bits: uint32) = triggers.add(bits)
proc nimFwRxDmaAfterInitProbe() = discard
proc rfPhyTraceCheckpoint(stage: uint32) =
  doAssert stage == 0x10 and irqLevel == 0
proc assert_err(file, condition: cstring; line: int) = inc errors
proc assert_rec(file, condition: cstring; line: int) = inc errors
proc reset() =
  headers = default(typeof(headers))
  payloads = default(typeof(payloads))
  lower = default(RxlCntrlEnvView)
  hardware = default(RxHwDescEnvView)
  triggers.setLen(0)
  forgotten.setLen(0)
  hdSubmitted = 0
  pdSubmitted = 0
  hdHead = 0
  pdHead = 0
  enters = 0
  exits = 0
  errors = 0
  txControlState.resetInProgress = 0
  resetEvents = 0
  disabledMacIrqs = 0
  irqLevel = 8
  rxInitializationEpoch = 0
  for i in 0 ..< WifiRxRingSlots:
    headers[i].magic = 0x12345678
    headers[i].next = addr headers[(i + 3) mod WifiRxRingSlots]
    headers[i].flags = 0xFFFF0001'u32
    headers[i].bufferAddr = 0x34567890
    headers[i].tsfLow = 0xB6B61234'u32
    payloads[i].magic = 0x23456789
    payloads[i].next = addr payloads[(i + 5) mod WifiRxRingSlots]
    payloads[i].status = 0xA5A51234'u32
'''


def source() -> str:
    lower = (FW / "rx_layer.nim").read_text()
    code = PLATFORM + layouts(
        "RxHeaderHwDescView", "RxPayloadHwDescView", "RxPayloadBufferView",
        "RxSwTableDescView", "RxDmaProgressDescView", "RxlCntrlEnvView",
        "RxHwDescEnvView",
    ) + SUPPORT
    code += procedure((FW / "runtime_helpers.nim").read_text(), "wifiDmaStoreLink")
    names = ["rxl_hwdesc_init", "rxl_hd_append", "rxl_pd_append"]
    if "proc rxInitializeHwDescriptors(" in lower:
        names.insert(0, "rxInitializeHwDescriptors")
    for name in names:
        body = procedure(lower, name)
        if name == "rxl_hd_append":
            # Keep the selected pointer intact on a 64-bit host; the hardware
            # address comparison still uses the firmware's 32-bit value.
            body = body.replace(
                "let envCur = cast[uint32](env.currentHd)",
                "let originalCurrent = env.currentHd\n"
                "  let envCur = cast[uint32](originalCurrent)",
            ).replace("appendDesc = cast[pointer](envCur)",
                      "appendDesc = originalCurrent")
        code += body
    return code


CASES = {
    "init_payload_status": r'''
for full in 0'u32 .. 1:
  reset()
  rxl_hwdesc_init(full)
  for payload in payloads:
    doAssert payload.status == 0xA5A50000'u32,
      "initialization must clear bufstatinfo without changing reserved"
  doAssert enters == 1 and exits == 1 and irqLevel == 8
''',
    "init_header_length": r'''
for full in 0'u32 .. 1:
  reset()
  rxl_hwdesc_init(full)
  for header in headers:
    doAssert header.tsfLow == 0xB6B60000'u32,
      "initialization must clear frmlen without changing ampdu_stat_info"
  doAssert enters == 1 and exits == 1 and irqLevel == 8
''',
    "init_chains": r'''
for full in 0'u32 .. 1:
  for initialIrq in [0'u32, 8]:
    reset()
    irqLevel = initialIrq
    for i in 0 ..< WifiRxRingSlots:
      headers[i].usedFlag = (i mod 4 == 1).uint32
      payloads[i].usedFlag = (i mod 3 == 1).uint32
    let originalHeaders = headers
    let originalPayloads = payloads
    var eligibleHeaders, eligiblePayloads: seq[int]
    for i in 0 ..< WifiRxRingSlots:
      if full != 0 or headers[i].usedFlag != 1: eligibleHeaders.add(i)
      if full != 0 or payloads[i].usedFlag != 1: eligiblePayloads.add(i)
    rxl_hwdesc_init(full)
    doAssert lower.currentHd == addr headers[eligibleHeaders[0]]
    doAssert lower.submittedHead == addr headers[eligibleHeaders[1]]
    doAssert lower.submittedTail == addr headers[eligibleHeaders[^1]]
    doAssert hardware.pdCurrent == addr payloads[eligiblePayloads[0]]
    doAssert hardware.pdTail == addr payloads[eligiblePayloads[^1]]
    doAssert hdSubmitted == pointerAddrU32(lower.submittedHead)
    doAssert pdSubmitted == pointerAddrU32(addr payloads[eligiblePayloads[1]])
    doAssert triggers == @[0x04000000'u32, 0x08000000'u32]
    doAssert forgotten == eligibleHeaders
    for position, i in eligibleHeaders:
      let next = if position + 1 < eligibleHeaders.len:
        cast[pointer](addr headers[eligibleHeaders[position + 1]]) else: nil
      doAssert headers[i].next == next
      doAssert headers[i].magic == 0xBAADF00D'u32
      doAssert headers[i].bufferAddr == 0 and headers[i].flags == 0
      doAssert headers[i].swDesc == pointerAddrU32(addr software[i])
    for position, i in eligiblePayloads:
      let next = if position + 1 < eligiblePayloads.len:
        cast[pointer](addr payloads[eligiblePayloads[position + 1]]) else: nil
      doAssert payloads[i].next == next
      doAssert payloads[i].magic == 0xC0DEDBAD'u32
      doAssert payloads[i].bufferAddr == pointerAddrU32(addr buffers[i].payloadBytes[0])
      doAssert payloads[i].bufferStart == payloads[i].bufferAddr
      doAssert payloads[i].bufferEnd == payloads[i].bufferAddr + 1735
    if full == 0:
      for i in 0 ..< WifiRxRingSlots:
        if i notin eligibleHeaders: doAssert headers[i] == originalHeaders[i]
        if i notin eligiblePayloads: doAssert payloads[i] == originalPayloads[i]
    doAssert enters == 1 and exits == 1 and irqLevel == initialIrq
''',
    "append_payload": r'''
for matchesHardware in [false, true]:
  for multiple in [false, true]:
    reset()
    hardware.pdCurrent = addr payloads[0]
    hardware.pdTail = addr payloads[1]
    pdHead = pointerAddrU32(if matchesHardware: addr payloads[0] else: addr payloads[payloads.high])
    let first = if multiple: addr payloads[2] else: addr payloads[4]
    let previous = if multiple: cast[pointer](addr payloads[3]) else: nil
    payloads[2].next = addr payloads[3]
    payloads[3].next = addr payloads[4]
    let old = payloads
    rxl_pd_append(first, previous, addr payloads[4])
    let selected = if matchesHardware: 4 else: 0
    let tail = if matchesHardware: 4 elif multiple: 3 else: 0
    let head = if not matchesHardware: 0 elif multiple: 2 else: 4
    doAssert payloads[selected].status == 0xA5A50000'u32
    doAssert payloads[tail].next == nil
    doAssert payloads[1].next == addr payloads[head]
    doAssert hardware.pdTail == addr payloads[tail]
    doAssert hardware.pdCurrent == addr payloads[if matchesHardware: 0 else: 4]
    if not matchesHardware and multiple:
      doAssert payloads[0].next == addr payloads[2]
    for i in 0 ..< WifiRxRingSlots:
      if i != selected: doAssert payloads[i].status == old[i].status
      doAssert payloads[i].usedFlag == old[i].usedFlag
    doAssert triggers == @[0x02000000'u32] and errors == 0
reset()
rxl_pd_append(nil, nil, nil)
doAssert errors == 1 and triggers.len == 0
''',
    "append_header": r'''
for matchesHardware in [false, true]:
  for empty in [false, true]:
    reset()
    lower.currentHd = addr headers[0]
    lower.submittedTail = addr headers[1]
    lower.submittedHead = if empty: nil else: addr headers[1]
    hdHead = pointerAddrU32(if matchesHardware: addr headers[0] else: addr headers[headers.high])
    let old = headers
    rxl_hd_append(addr headers[2])
    let selected = if matchesHardware: 2 else: 0
    doAssert headers[selected].tsfLow == 0xB6B60000'u32
    doAssert headers[selected].flags == 0 and headers[selected].bufferAddr == 0
    doAssert headers[selected].next == nil
    doAssert headers[1].next == addr headers[selected]
    doAssert lower.submittedTail == addr headers[selected]
    doAssert lower.currentHd == addr headers[if matchesHardware: 0 else: 2]
    doAssert lower.submittedHead == addr headers[if empty: selected else: 1]
    doAssert forgotten == @[selected] and triggers == @[0x01000000'u32]
    for i in 0 ..< WifiRxRingSlots:
      if i != selected and i != 1: doAssert headers[i] == old[i]
    doAssert errors == 0
reset()
rxl_hd_append(nil)
doAssert errors == 1 and triggers.len == 0 and forgotten.len == 0
''',
    "recycle_ring": r'''
reset()
rxl_hwdesc_init(1)
var firstPayload: pointer = addr payloads[1]
for cycle in 0 ..< 123:
  let releasedHeader = lower.submittedHead
  let releasedPayload = firstPayload
  lower.submittedHead = rxHeaderHwDescView(releasedHeader).next
  firstPayload = rxDmaProgressDescAt(releasedPayload).next
  let matchesHardware = cycle mod 2 == 0
  hdHead = if matchesHardware: pointerAddrU32(lower.currentHd) else: 0
  pdHead = if matchesHardware: pointerAddrU32(hardware.pdCurrent) else: 0
  rxl_pd_append(releasedPayload, nil, releasedPayload)
  rxl_hd_append(releasedHeader)
  var seenHeaders, seenPayloads: array[WifiRxRingSlots, bool]
  var header = lower.submittedHead
  var payload = firstPayload
  for position in 0 ..< (WifiRxRingSlots - 1):
    doAssert header != nil and payload != nil
    doAssert header != lower.currentHd and payload != hardware.pdCurrent
    var headerIndex, payloadIndex = -1
    for i in 0 ..< WifiRxRingSlots:
      if header == addr headers[i]: headerIndex = i
      if payload == addr payloads[i]: payloadIndex = i
    doAssert headerIndex >= 0 and payloadIndex >= 0
    doAssert not seenHeaders[headerIndex] and not seenPayloads[payloadIndex]
    seenHeaders[headerIndex] = true
    seenPayloads[payloadIndex] = true
    if position == (WifiRxRingSlots - 2):
      doAssert header == lower.submittedTail and payload == hardware.pdTail
    header = rxHeaderHwDescView(header).next
    payload = rxDmaProgressDescAt(payload).next
  doAssert header == nil and payload == nil
doAssert errors == 0 and irqLevel == 8
''',
}


@pytest.mark.parametrize("case", CASES)
@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
@pytest.mark.parametrize("slots", [8, 41])
def test_rx_dma_ring(tmp_path: Path, mode: str, case: str, slots: int) -> None:
    run_program(tmp_path, mode, source() + CASES[case], defines=(f"WifiRxRingSlots={slots}",))
