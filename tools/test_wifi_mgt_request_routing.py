"""Keep AP request routing stable across type-preserving frame-control flags."""

from pathlib import Path

import pytest

from test_wifi_mgt_receive import test_management_receive as run_receive


@pytest.mark.parametrize("frame_type", [0x0000, 0x00B0], ids=["association", "authentication"])
@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_unbound_request_selects_ap(tmp_path: Path, mode: str, frame_type: int) -> None:
    run_receive(tmp_path, mode, f"const Request = {frame_type}'u16\n" + r'''
for vif in 0'u8 .. 1:
  for incoming in [false, true]:
    for flags in [0'u16, 0x0800, 0x1000, 0x2000, 0x1800]:
      reset(Request or flags, vif, 255, 2)
      env.vifIdx = 255
      frame.addr3 = frame.addr1
      interrupts = incoming
      # A STA VIF with the same local address must not win just by list order.
      let other = vif xor 1
      vifs[other].vifType = 0
      vifs[other].macAddr = vifs[vif].macAddr
      vifs[other].next = addr vifs[vif]
      mgmt.activeList.first = addr vifs[other]
      discard rxu_mgt_frame_check(addr desc, 255)
      doAssert policyVif == vif and env.vifIdx == vif,
        "unbound request was routed away from its AP VIF"
      doAssert sent == 1 and destination == 5
      doAssert message[7] == 255 and message[8] == vif
      doAssert cast[ptr uint16](addr message[2])[] == (Request or flags)
      doAssert equalMem(addr message[32], addr frame, rx.mpduLengthBytes.int)
      doAssert interrupts == incoming
''')


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_request_routing_keeps_bssid_check(tmp_path: Path, mode: str) -> None:
    run_receive(tmp_path, mode, r'''
for request in [0x0000'u16, 0x00B0]:
  for flags in [0'u16, 0x0800]:
    for vif in 0'u8 .. 1:
      reset(request or flags, vif, 255, 2)
      env.vifIdx = 255
      # reset() uses a foreign BSSID in Addr3.
      doAssert frame.addr3 != frame.addr1
      discard rxu_mgt_frame_check(addr desc, 255)
      doAssert policyVif == 255 and sent == 0 and uploads == 0
      doAssert allocationCalls == 0 and env.vifIdx == 255
''')


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_request_routing_respects_captured_vif_epoch(tmp_path: Path, mode: str) -> None:
    run_receive(tmp_path, mode, r'''
for request in [0x0000'u16, 0x00B0]:
  for vif in 0'u8 .. 1:
    reset(request or 0x0800, vif, 255, 2)
    env.vifIdx = 255
    frame.addr3 = frame.addr1
    discard rxInvalidateVif(vif)
    doAssert rxu_mgt_frame_check(addr desc, 255) == 0
    doAssert policyCalls == 0 and sent == 0 and allocationCalls == 0
''')
