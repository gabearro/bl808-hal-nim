"""Exercise the archived multi-AP beacon interval/divisor behavior."""

from pathlib import Path

import pytest

from test_wifi_disconnect_tx import procedure
from test_wifi_message_allocation import run_program


VIF = Path(__file__).resolve().parents[1] / "src/bl808/wifi/fw/vif_management.nim"


def beacon_interval_source() -> str:
    return r'''
type
  Vif = object
    next: pointer
    vifIdx: uint8
    apBeaconInterval: uint16
    beaconDivisor, beaconCountdown: uint8
  Env = object
    activeList: tuple[first: pointer]
    apCount, primaryApIdx: uint8
const MACHW_BCN_INT_REG = 1'u32
var
  vifs: array[2, Vif]
  vif_info_tab: array[2, Vif]
  env: Env
  hwInterval: uint32
  writes, saves, restores: int
proc vifChannelAt(p: pointer): ptr Vif = cast[ptr Vif](p)
proc vifChannelForIdx(index: uint8): ptr Vif = addr vifs[index]
proc vifMgmtEnvView(): ptr Env = addr env
proc irqSave(): uint32 =
  inc saves
  8'u32
proc irqRestore(saved: uint32) =
  doAssert saved == 8'u32
  inc restores
proc regRead(address: uint32): uint32 =
  doAssert address == MACHW_BCN_INT_REG
  hwInterval
proc regWrite(address, value: uint32) =
  doAssert address == MACHW_BCN_INT_REG
  inc writes
  hwInterval = value
''' + procedure(VIF.read_text(), "vif_mgmt_set_ap_bcn_int")


@pytest.mark.parametrize("mode", ["checked", "firmware"])
def test_multi_ap_divisor_and_zero_interval(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, beacon_interval_source() + r'''
proc checkTwoAp(oldInterval, newInterval, wantedMin: uint16;
                wantedOldDivisor, wantedNewDivisor, wantedPrimary: uint8) =
  vifs = default(typeof(vifs))
  env = default(typeof(env))
  vifs[0].vifIdx = 0
  vifs[1].vifIdx = 1
  vifs[0].apBeaconInterval = oldInterval
  vifs[0].next = cast[pointer](addr vifs[1])
  env.activeList.first = cast[pointer](addr vifs[0])
  env.apCount = 2
  env.primaryApIdx = 0
  hwInterval = 0xA5A50000'u32
  writes = 0
  saves = 0
  restores = 0
  vif_mgmt_set_ap_bcn_int(cast[pointer](addr vifs[1]), newInterval)
  doAssert vifs[0].beaconDivisor == wantedOldDivisor
  doAssert vifs[1].beaconDivisor == wantedNewDivisor
  doAssert vifs[0].beaconCountdown == 1 and vifs[1].beaconCountdown == 1
  doAssert env.primaryApIdx == wantedPrimary
  doAssert hwInterval == (0xA5A50000'u32 or wantedMin.uint32)
  doAssert writes == 1 and saves == 1 and restores == 1

checkTwoAp(100, 50, 50, 2, 1, 1)
checkTwoAp(100, 200, 100, 1, 2, 0)
checkTwoAp(1, 256, 1, 1, 0, 0)
# RV32 DIVU returns all ones for a zero divisor; the stored low byte is 255.
checkTwoAp(100, 0, 0, 255, 255, 1)
checkTwoAp(0, 50, 0, 255, 255, 0)
''')
