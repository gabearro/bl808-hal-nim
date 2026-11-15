"""Reject incomplete AP authentication and teardown frames before side effects."""

from pathlib import Path

import pytest

from test_wifi_disconnect_tx import procedure
from test_wifi_message_allocation import run_program

ROOT = Path(__file__).resolve().parents[1]
FW = ROOT / "src/bl808/wifi/fw"

PLATFORM = r"""
const
  MAX_VIFS = 2
  STA_INFO_TAB_ENTRIES = 7
  VIF_TYPE_AP = 2'u8
  WLAN_FW_APM_DELETESTA_FOR_NEW_CONNECTION = 5
  WLAN_FW_APM_DEATUH_BY_STA = 2
  WLAN_FW_APM_DISASSOCIATE_BY_STA = 3
type
  Header = object
    paramLen: uint32
  Vif = object
    vifType, state, apChanSwitchPending: uint8
    chanCtxt: pointer
  Station = object
    macAddr: array[6, uint8]
    valid, instNbr: uint8
var
  header: Header
  payload: pointer
  vifs: array[2, Vif]
  station: Station
  apmPendingCancelMask, apmStoppingVifs, startupMask: uint8
  rxVifEpochs: array[2, uint32]
  lookups, channelChecks, triggers, deletions, sends, logLookups: int
  kind: int
  expectedReason = 0x1234'u16
  sourceMac = [2'u8, 3, 4, 5, 6, 7]
proc malloc(n: csize_t): pointer {.importc, header: "<stdlib.h>".}
proc free(p: pointer) {.importc, header: "<stdlib.h>".}
proc keMsgHdrFromPayload(p: pointer): ptr Header =
  doAssert p == payload
  addr header
proc apmRxMgmtPrefix(p: pointer): ptr ApmRxMgmtPrefixView =
  cast[ptr ApmRxMgmtPrefixView](p)
proc apmStartPendingForVif(vif: uint8): bool = (startupMask and (1'u8 shl vif)) != 0
proc vifChannelForIdx(vif: uint8): ptr Vif =
  doAssert vif < 2
  addr vifs[vif]
proc staInfoForIdx(index: uint8): ptr Station =
  doAssert index == 3
  addr station
proc staDeleteEpoch(sta: uint8): uint32 = 0
proc staDeleteIsCurrent(sta: uint8; epoch: uint32): bool = true
proc c_memcmp(a, b: pointer; length: csize_t): cint =
  (not equalMem(a, b, length.int)).cint
proc getLogFunc(slot: int): pointer =
  doAssert slot == 204
  inc logLookups
  nil
proc hal_machw_search_addr(mac: pointer; unused: uint8): uint32 =
  doAssert equalMem(mac, addr sourceMac[0], 6)
  inc lookups
  3
proc chan_ctxt_cnt(): uint32 =
  inc channelChecks
  2
proc chan_ctxt_trigger(context: pointer) =
  doAssert context == cast[pointer](0x1234)
  inc triggers
proc apm_sta_delete(sta: uint8; mac: pointer; status, reason: uint16): bool =
  doAssert sta == 3 and equalMem(mac, addr sourceMac[0], 6)
  doAssert status == [5'u16, 2, 3][kind]
  doAssert reason == (if kind == 0: 65535'u16 else: expectedReason)
  inc deletions
  true
proc apm_send_mlme(vif: pointer; frameType: uint16; destination: pointer;
                   callback, argument, extra: pointer) =
  doAssert vif == (addr vifs[1]) and callback == nil and argument == nil
  doAssert equalMem(destination, addr sourceMac[0], 6)
  doAssert frameType == (if kind == 0: 0xB0'u16 else: 0xC0'u16)
  doAssert extra == (if kind == 0: nil else: cast[pointer](2))
  inc sends
proc setup(frameLength: uint16; allocation: int) =
  if payload != nil: free(payload)
  payload = malloc(max(1, allocation).csize_t)
  doAssert payload != nil
  zeroMem(payload, max(1, allocation))
  header.paramLen = allocation.uint32
  let bytes = cast[ptr UncheckedArray[uint8]](payload)
  if allocation >= 2:
    bytes[0] = (frameLength and 255).uint8
    bytes[1] = (frameLength shr 8).uint8
  if allocation >= 9:
    bytes[7] = 3
    bytes[8] = 1
  if allocation >= 48:
    for i, value in sourceMac: bytes[42 + i] = value
  if allocation >= 58:
    bytes[56] = (expectedReason and 255).uint8
    bytes[57] = (expectedReason shr 8).uint8
  vifs[1] = Vif(vifType: 2, state: 1, chanCtxt: cast[pointer](0x1234))
  station = Station(macAddr: sourceMac, valid: 1, instNbr: 1)
  lookups = 0
  channelChecks = 0
  triggers = 0
  deletions = 0
  sends = 0
  logLookups = 0
"""

CHECKS = r"""
proc receive() =
  case kind
  of 0: apm_auth_handler(payload)
  of 1: apm_deauth_handler(payload)
  else: apm_disassoc_handler(payload)
proc expectIgnored() =
  receive()
  doAssert lookups == 0 and channelChecks == 0 and triggers == 0
  doAssert deletions == 0 and sends == 0 and logLookups == 0,
    "incomplete AP frame caused a protocol side effect"

# The producer pads short messages to 68 bytes; allocation size is not frame length.
kind = 0
setup(24, 68)
expectIgnored()

for frameKind in 0 .. 2:
  kind = frameKind
  let minimum = if kind == 0: 30 else: 26
  for length in 0 ..< minimum:
    setup(length.uint16, 68)
    expectIgnored()
  # Use exact allocations to exercise prefix reads with AddressSanitizer.
  for length in 0 ..< 32 + minimum:
    setup(minimum.uint16, length)
    expectIgnored()
  for frameLength in [minimum + 1, 65535]:
    setup(frameLength.uint16, 32 + minimum)
    expectIgnored()
  for frameLength in [minimum, minimum + 1, minimum + 7]:
    for padding in [0, 10]:
      setup(frameLength.uint16, 32 + frameLength + padding)
      receive()
      doAssert deletions == 1
      if kind == 0:
        doAssert lookups == 1 and channelChecks == 1 and triggers == 1
        doAssert sends == 1 and logLookups == 0
      else:
        doAssert lookups == 0 and channelChecks == 0 and triggers == 0
        doAssert sends == (kind == 2).int and logLookups == 1
  free(payload)
  payload = nil
  receive()
free(payload)
"""


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_ap_rx_frame_lengths(tmp_path: Path, mode: str) -> None:
    layout = (FW / "layout_types.nim").read_text()
    name = "ApmRxMgmtPrefixView"
    types = "type\n  " + name + layout.split("  " + name, 1)[1].split("\n\n  ", 1)[0] + "\n"
    scan = (FW / "scan_station_ap_me.nim").read_text()
    functions = procedure((FW / "task_handlers.nim").read_text(), "apmVifRunning")
    functions += procedure(scan, "apmSessionCurrent")
    if "proc apmRxFrameFits(" in scan:
        functions += procedure(scan, "apmRxFrameFits")
    for handler in ["apm_auth_handler", "apm_deauth_handler", "apm_disassoc_handler"]:
        functions += procedure(scan, handler)
    run_program(tmp_path, mode, types + PLATFORM + functions + CHECKS)
