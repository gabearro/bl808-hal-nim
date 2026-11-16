"""Keep upper-RX continuation bound to its captured descriptor generation."""

from pathlib import Path

import pytest

from test_wifi_disconnect_tx import FW, procedure
from test_wifi_message_allocation import run_program
import test_wifi_rx_key_epoch as keys


MODES = ["checked", "release", "asan", "firmware"]


def source(connect_trace: bool = True) -> str:
    code = keys.source()
    for old, declaration in (
        ("proc rxUploadGeneration(p: pointer): uint32 = rxGeneration\n",
         "proc rxUploadGeneration(desc: pointer): uint32\n"),
        ("proc rxUploadCurrent(p: pointer; generation: uint32): bool = generation == rxGeneration\n",
         "proc rxUploadCurrent(desc: pointer; generation: uint32): bool\n"),
    ):
        assert old in code
        code = code.replace(old, declaration, 1)
    lower = (FW / "rx_layer.nim").read_text()
    code += procedure(lower, "rxUploadGeneration") + procedure(lower, "rxUploadCurrent")
    code = code.replace(procedure(code, "irqSave"), r'''
proc irqSave(): uint32 =
  result = interrupts.uint32 * 8
  # Model an interrupt completing immediately before MIE is cleared.
  if interrupts and pendingIrqs > 0:
    dec pendingIrqs
    if pendingIrqs == 0:
      let callback = onRxIrq
      onRxIrq = nil
      callback()
  interrupts = false
''', 1)
    code = code.replace(
        "template nimFwTrace2U32(args: varargs[untyped]) = discard\n", "", 1)
    code = code.replace(procedure(code, "rxu_mgt_frame_check"), r'''
proc rxu_mgt_frame_check(p: pointer; sta: uint8): uint32 =
  inc managementCalls
  0
''', 1)
    return ("{.define: bl808WifiConnectTrace.}\n" if connect_trace else "") + r'''
var
  onRxTrace: proc(label: string)
  onRxIrq: proc()
  pendingIrqs, managementCalls: int
  traceSeen: seq[string]
const
  TASK_SM = 4
  SmAuthStartingState = 2'u16
proc ke_state_get(task: int): uint16 = SmAuthStartingState
proc traceBoundary(label: string) =
  traceSeen.add(label)
  if onRxTrace != nil: onRxTrace(label)
proc nimFwTrace2U32(label: string; a, b: uint32) = traceBoundary(label)
proc nimFwConnectTrace2U32(label: string; a, b: uint32) = traceBoundary(label)
proc nimFwConnectTraceBytes(label: string; p: pointer; length, limit: uint32) =
  traceBoundary(label)
''' + code + r'''
var
  snapshotStations: typeof(stations)
  snapshotVifs: typeof(vifs)
  snapshotKey: typeof(key)
  snapshotSw: typeof(sw)
  snapshotBytes: typeof(bytes)
  snapshotMpdu: typeof(mpdu)
  snapshotReplay, snapshotMic, snapshotEapol, snapshotTransfer: int
  replacementSeen: bool

proc prepareFrame(fc: uint16; cipher: int; protocol: uint16;
                  ap, enabled: bool) =
  onRxTrace = nil
  onRxIrq = nil
  pendingIrqs = 0
  managementCalls = 0
  traceSeen.setLen(0)
  replacementSeen = false
  let wireFc = fc or (if cipher == 0: 0'u16 else: 0x4000'u16)
  prepare(wireFc)
  vifs[0].vifType = if ap: 2 else: 0
  let hdr = macDataFrameAt(addr bytes[0])
  vifs[0].macAddr = if (fc and 0x0100'u16) != 0: hdr.addr3 else: hdr.addr1
  sw.hwFlags = (sw.hwFlags and not 0x1C'u32) or
    (if cipher == 1: 24'u32 else: 28'u32)
  key.cipherType = if cipher == 1: 1 else: 2
  let header = rxu_cntrl_machdr_len_get(wireFc).int + (if cipher == 0: 0 else: 8)
  if (fc and 0x000C'u16) == 8:
    snapAt(header, protocol)
    if cipher == 1:
      for i in 0 ..< 8: bytes[sw.mpduLengthBytes.int + i] = (i + 1).uint8
      sw.mpduLengthBytes += 8
  interrupts = enabled
  doAssert rxStationCurrent(addr mpdu)

proc replaceFrame(kind: int) =
  replacementSeen = true
  case kind
  of 0:
    let previous = rxUploadGeneration(addr mpdu)
    rxCaptureStation(addr mpdu, sw.hwFlags)
    doAssert rxUploadGeneration(addr mpdu) != previous
    doAssert rxStationCurrent(addr mpdu), "replacement has a valid current station"
    sw.frameControlFlags = 0x13579BDF
    sw.bufferOffset = 0x2468ACE0
  of 1: mpdu.swDesc = nil
  of 2: inc stationEpochs[0]
  else: inc rxVifEpochs[0]
  snapshotStations = stations
  snapshotVifs = vifs
  snapshotKey = key
  snapshotSw = sw
  snapshotBytes = bytes
  snapshotMpdu = mpdu
  snapshotReplay = replayCalls
  snapshotMic = micCalls
  snapshotEapol = eapolCalls
  snapshotTransfer = transferred

proc checkReplacement() =
  doAssert replacementSeen
  doAssert stations == snapshotStations and vifs == snapshotVifs and key == snapshotKey,
    "old RX continuation changed replacement station/key state"
  doAssert sw == snapshotSw and bytes == snapshotBytes and mpdu == snapshotMpdu,
    "old RX continuation rewrote a replaced frame"
  doAssert replayCalls == snapshotReplay and micCalls == snapshotMic
  doAssert eapolCalls == snapshotEapol and transferred == snapshotTransfer
  doAssert prepared == 0 and managementCalls == 0
'''


@pytest.mark.parametrize("mode", MODES)
def test_data_trace_stops_after_frame_replacement(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for enabled in [false, true]:
  for ap in [false, true]:
    for fc in [0x0088'u16, 0x0388, 0x8088, 0x8388]:
      for cipher in 0 .. 2:
        for protocol in [0x0800'u16, 0x888E]:
          for kind in 0 .. 3:
            prepareFrame(fc or (if ap: 0x0100'u16 else: 0x0200'u16), cipher, protocol, ap, enabled)
            onRxTrace = proc(label: string) =
              if label == "[WIFI-CT] rx_data ": replaceFrame(kind)
            doAssert rxu_cntrl_frame_handle(addr mpdu) == 0
            checkReplacement()
            doAssert traceSeen[^1] == "[WIFI-CT] rx_data " and interrupts == enabled
''')


@pytest.mark.parametrize("mode", MODES)
def test_protected_header_key_check_keeps_the_frame_generation(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for ap in [false, true]:
  for fc in [0x0288'u16, 0x0388, 0x00D0]:
    for cipher in [1, 2]:
      if (fc and 0x000C'u16) == 0 and cipher == 1: continue
      for kind in 0 .. 3:
        prepareFrame(fc, cipher, 0x0800, ap, true)
        onRxTrace = proc(label: string) =
          if label == "[WIFI-RAW] rx_any ":
            pendingIrqs = 1
            onRxIrq = proc() = replaceFrame(kind)
        doAssert rxu_cntrl_frame_handle(addr mpdu) == 0
        checkReplacement()
        doAssert traceSeen[^1] == "[WIFI-RAW] rx_any " and interrupts
''')


@pytest.mark.parametrize("mode", MODES)
def test_data_commit_checks_the_captured_generation(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for ap in [false, true]:
  for fc in [0x0008'u16, 0x0088, 0x0388, 0x8388]:
    for cipher in 0 .. 2:
      for protocol in [0x0800'u16, 0x888E]:
        for irqPhase in 1 .. 3:
          if cipher != 1 and irqPhase != 1: continue
          for kind in 0 .. 3:
            prepareFrame(fc or (if ap: 0x0100'u16 else: 0x0200'u16), cipher, protocol, ap, true)
            onRxTrace = proc(label: string) =
              if label == "[WIFI-CT] rx_data ":
                pendingIrqs = irqPhase
                onRxIrq = proc() = replaceFrame(kind)
            doAssert rxu_cntrl_frame_handle(addr mpdu) == 0
            checkReplacement()
            doAssert pendingIrqs == 0 and interrupts
''')


@pytest.mark.parametrize("mode", MODES)
def test_management_commit_checks_the_captured_generation(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for fc in [0x00D0'u16, 0x00A0, 0x00C0]:
  for cipher in [0, 2]:
    for kind in 0 .. 3:
      prepareFrame(fc, cipher, 0, false, true)
      onRxTrace = proc(label: string) =
        if label == "[WIFI-RAW] rx_any ":
          pendingIrqs = if cipher == 0: 1 else: 2
          onRxIrq = proc() = replaceFrame(kind)
      doAssert rxu_cntrl_frame_handle(addr mpdu) == 0
      checkReplacement()
      doAssert pendingIrqs == 0 and interrupts
''')


@pytest.mark.parametrize("mode", MODES)
def test_current_data_continues_across_diagnostics(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for enabled in [false, true]:
  for ap in [false, true]:
    for fc in [0x0008'u16, 0x0088, 0x0388, 0x8388]:
      for cipher in 0 .. 2:
        for protocol in [0x0800'u16, 0x888E]:
          prepareFrame(fc or (if ap: 0x0100'u16 else: 0x0200'u16), cipher, protocol, ap, enabled)
          onRxTrace = proc(label: string) =
            inc stationEpochs[1]
            inc rxVifEpochs[1]
          let expected = (protocol != 0x888E).uint32
          doAssert rxu_cntrl_frame_handle(addr mpdu) == expected
          doAssert transferred == expected.int and prepared == expected.int
          doAssert eapolCalls == (protocol == 0x888E).int
          doAssert replayCalls == (cipher != 0).int and managementCalls == 0
          doAssert not replacementSeen and interrupts == enabled
''')


@pytest.mark.parametrize("mode", MODES)
def test_earlier_trace_replacement_also_stops(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for enabled in [false, true]:
  for label in ["[WIFI-NIMFW] rxu_fc ", "[WIFI-CT] rx_enter ",
                "[WIFI-CT] rx_len ", "[WIFI-RAW] rx_any ", "[WIFI-CT] eapol_rx "]:
    for kind in 0 .. 3:
      prepareFrame(0x0288, 0, 0x888E, false, enabled)
      onRxTrace = proc(actual: string) =
        if actual == label: replaceFrame(kind)
      doAssert rxu_cntrl_frame_handle(addr mpdu) == 0
      checkReplacement()
      doAssert traceSeen[^1] == label and interrupts == enabled
''')


@pytest.mark.parametrize("mode", MODES)
def test_current_management_reaches_dispatch(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for enabled in [false, true]:
  for fc in [0x00D0'u16, 0x00A0, 0x00C0]:
    for cipher in [0, 2]:
      prepareFrame(fc, cipher, 0, false, enabled)
      doAssert rxu_cntrl_frame_handle(addr mpdu) == 0
      doAssert managementCalls == 1 and replayCalls == (cipher != 0).int
      doAssert transferred == 0 and prepared == 0 and eapolCalls == 0
      doAssert interrupts == enabled
''')


@pytest.mark.parametrize("mode", MODES)
def test_without_connect_trace_keeps_the_frame_generation(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source(False) + r'''
for ap in [false, true]:
  for fc in [0x0288'u16, 0x0388, 0x8388, 0x00D0]:
    for cipher in 0 .. 2:
      let management = (fc and 0x000C'u16) == 0
      if management and cipher == 1: continue
      for protocol in [0x0800'u16, 0x888E]:
        for enabled in [false, true]:
          prepareFrame(fc, cipher, protocol, ap, enabled)
          let data = not management and protocol != 0x888E
          doAssert rxu_cntrl_frame_handle(addr mpdu) == data.uint32
          doAssert transferred == data.int and prepared == data.int
          doAssert managementCalls == management.int
          doAssert eapolCalls == (not management and protocol == 0x888E).int
          doAssert interrupts == enabled
        let boundaries = if cipher == 0: 1 elif cipher == 1: 4 else: 2
        for phase in 1 .. boundaries:
          for kind in 0 .. 3:
            prepareFrame(fc, cipher, protocol, ap, true)
            pendingIrqs = phase
            onRxIrq = proc() = replaceFrame(kind)
            doAssert rxu_cntrl_frame_handle(addr mpdu) == 0
            checkReplacement()
            doAssert pendingIrqs == 0 and interrupts
''')
