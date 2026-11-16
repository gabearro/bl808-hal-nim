"""Validate frame-control fields before RX address, replay or peer work."""

from pathlib import Path

import pytest

from test_wifi_message_allocation import run_program
from test_wifi_rx_admission import admission_source
from test_wifi_rx_mgmt_cipher import source as management_source


def dispatch_source() -> str:
    code = management_source()
    original_upload = "proc rxu_mpdu_upload_and_indicate(p: pointer) = discard\n"
    assert code.count(original_upload) == 1
    code = code.replace(original_upload, r'''
var rawUploads: int
proc rxu_mpdu_upload_and_indicate(p: pointer) =
  inc rawUploads
  mpdu.curDesc = cast[pointer](1)
''', 1)
    return code + r'''
proc packetMalloc(size: csize_t): pointer {.importc: "malloc", header: "<stdlib.h>".}
proc packetFree(p: pointer) {.importc: "free", header: "<stdlib.h>".}
proc prepareFrame(fc: uint16; associated, enabled: bool; length = -1) =
  prepare(fc, 28, associated, true, false, false, enabled)
  if length >= 0: sw.mpduLengthBytes = length.uint16
  rawUploads = 0
  envState.da = [0xA2'u8, 1, 2, 3, 4, 5]
  envState.sa = [0xB2'u8, 6, 7, 8, 9, 10]
  envState.bssidSeq = 0xFED0
  sw.frameControlFlags = 0xA123
  rxu_cntrl_duplicate_flag = 7
proc rejectFrame(enabled: bool; exact = false) =
  let length = sw.mpduLengthBytes.int
  var packet: pointer
  if exact:
    # Direct malloc makes the ASan allocation boundary equal the MPDU length.
    packet = packetMalloc(length.csize_t)
    doAssert packet != nil
    copyMem(packet, addr bytes[0], length)
    chain.frameData = packet
  let before = bytes
  let beforeEnv = envState
  let beforeSw = sw
  let beforeKey = key
  let beforeCounter = managementCounter
  let beforeStations = stations
  let beforeVifs = vifs
  let beforeDuplicate = rxu_mgmt_dup_addr
  try:
    doAssert rxu_cntrl_frame_handle(addr mpdu) == 0
    doAssert managementCalls == 0 and rawUploads == 0 and keySelections == 0,
      "invalid FC reached management/raw publication or key selection"
    doAssert transferred == 0 and prepared == 0 and eapolCalls == 0 and micCalls == 0
    doAssert envState == beforeEnv and sw == beforeSw,
      "invalid FC changed RX header/address/duplicate state"
    doAssert key == beforeKey and managementCounter == beforeCounter
    doAssert stations == beforeStations and vifs == beforeVifs
    doAssert bytes == before and rxu_mgmt_dup_addr == beforeDuplicate
    doAssert rxu_cntrl_duplicate_flag == 7 and interrupts == enabled
    if exact: doAssert cmpMem(packet, addr bytes[0], length) == 0
  finally:
    if exact: packetFree(packet)
'''


DIRECT_CASES = {
    "management-addr4-boundary": r'''
for order in [0'u16, 0x8000]:
  for associated in [false, true]:
    for enabled in [false, true]:
      let fc = 0x03D0'u16 or order
      prepareFrame(fc, associated, enabled, rxMacHeaderLen(fc).int)
      rejectFrame(enabled, exact = true)
''',
    "management-ds-fields": r'''
for subtype in countup(0'u16, 0xF0'u16, 0x10'u16):
  for ds in [0x100'u16, 0x200, 0x300]:
    for flags in [0'u16, 0x8000, 0x4000, 0xC000]:
      for associated in [false, true]:
        for enabled in [false, true]:
          prepareFrame(subtype or ds or flags, associated, enabled)
          rejectFrame(enabled)
''',
    "control-ds-fields": r'''
for subtype in countup(4'u16, 0xF4'u16, 0x10'u16):
  for ds in [0x100'u16, 0x200, 0x300]:
    for associated in [false, true]:
      for enabled in [false, true]:
        let fc = subtype or ds
        prepareFrame(fc, associated, enabled, rxMacHeaderLen(fc).int)
        rejectFrame(enabled, exact = true)
''',
    "protocol-version": r'''
for base in [0x00D0'u16, 0x00D4, 0x00A4, 0x0008, 0x0388, 0x8388, 0x40D0]:
  for version in 1'u16..3:
    for associated in [false, true]:
      for enabled in [false, true]:
        prepareFrame(base or version, associated, enabled)
        rejectFrame(enabled)
''',
    "valid-management-and-control": r'''
for fc in [0x00B0'u16, 0x00D0, 0x80D0]:
  for associated in [false, true]:
    for enabled in [false, true]:
      prepareFrame(fc, associated, enabled)
      doAssert rxu_cntrl_frame_handle(addr mpdu) == 0
      doAssert managementCalls == 1 and rawUploads == 0 and keySelections == 0
      doAssert envState.da == macDataFrameAt(addr bytes[0]).addr1
      doAssert envState.sa == macDataFrameAt(addr bytes[0]).addr2
      doAssert interrupts == enabled
for fc in [0x00C4'u16, 0x00D4, 0x00A4, 0x00B4, 0x0094]:
  for enabled in [false, true]:
    prepareFrame(fc, false, enabled, rxMacHeaderLen(fc).int)
    doAssert rxu_cntrl_frame_handle(addr mpdu) == 1
    doAssert rawUploads == 1 and managementCalls == 0 and keySelections == 0
    doAssert interrupts == enabled
''',
}


ADMISSION_CASES = {
    "nondata-ds-fields": r'''
for kind in [0'u16, 4]:
  for subtype in countup(0'u16, 0xF0'u16, 0x10'u16):
    for ds in [0x100'u16, 0x200, 0x300]:
      for flags in [0'u16, 0x8000, 0x4000, 0xC000]:
        let fc = kind or subtype or ds or flags
        reset(fc, rxMacHeaderLen(fc).uint16 + 40)
        dispatch()
        doAssert powerCalls == 0 and clockCalls == 0 and upperCalls == 0,
          "invalid non-data DS fields reached peer processing"
        doAssert freed == 1 and recovered == 0 and stas[4].connectionStart == 0
''',
    "protocol-version": r'''
for base in [0x00D0'u16, 0x00D4, 0x00A4, 0x0008, 0x0388, 0x8388, 0x40D0]:
  for version in 1'u16..3:
    reset(base or version, 100)
    dispatch()
    doAssert powerCalls == 0 and clockCalls == 0 and upperCalls == 0
    doAssert freed == 1 and recovered == 0 and stas[4].connectionStart == 0
''',
    "valid-frame-control": r'''
# Length classification remains independent of FC validity; data keeps all DS combinations.
for fc in [0x00D0'u16, 0x80D0, 0x00D4, 0x00A4,
           0x0008, 0x0108, 0x0208, 0x0308, 0x0388, 0x8388]:
  reset(fc, rxMacHeaderLen(fc).uint16 + 40)
  var header: ptr RxSwDescView
  doAssert rxAdmitMpdu(rxSwTableDescAt(0), header) == rxFrameReady
  dispatch()
  doAssert powerCalls == 1 and clockCalls == 1 and upperCalls == 1
  doAssert freed == 1 and recovered == 0 and interrupts
''',
}


@pytest.mark.parametrize("mode", ["checked", "release", "asan", "firmware"])
@pytest.mark.parametrize("case", DIRECT_CASES)
def test_direct_frame_control(case: str, mode: str, tmp_path: Path) -> None:
    run_program(tmp_path, mode, dispatch_source() + DIRECT_CASES[case])


@pytest.mark.parametrize("mode", ["checked", "release", "asan", "firmware"])
@pytest.mark.parametrize("case", ADMISSION_CASES)
def test_admission_frame_control(case: str, mode: str, tmp_path: Path) -> None:
    run_program(tmp_path, mode, admission_source(ADMISSION_CASES[case]))
