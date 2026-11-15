"""Check production station deletion and broadcast power-save cleanup."""

from pathlib import Path
import shutil
import subprocess

import pytest

from test_wifi_disconnect_tx import procedure

ROOT = Path(__file__).resolve().parents[1]

PLATFORM = r"""
const
  VIF_TYPE_STA = 0'u8
  TASK_MM = 0'u8
  TASK_API = 9'u8
  MM_PS_CHANGE_IND = 0x37'u16
  STA_MGMT_FREE_STAS = 5
  MmPsChangeIndPayloadSize = 2
type
  Sta = object
    instNbr, psMode: uint8
  Security = object
    connected, cipher: uint8
    staKeySlots: array[4, uint8]
  Vif = object
    vifType, vifIdx, staIdx, psBaCounter: uint8
    security: Security
  MmPsChangeIndPayload = object
    staIdx, psState: uint8
  StaQueueIdentity = object
    entry: pointer
    vif: uint8
var
  stations: array[7, Sta]
  vifs: array[2, Vif]
  keepalive: uint32
  message: MmPsChangeIndPayload
  failAllocation: bool
  events: seq[string]
  keys: seq[uint8]
proc staInfoForIdx(index: uint8): ptr Sta = addr stations[index]
proc staInfoAt(p: pointer): ptr Sta = cast[ptr Sta](p)
proc vifChannelForIdx(index: uint8): ptr Vif = addr vifs[index]
proc vifSecurity(p: ptr Vif): ptr Security = addr p.security
proc ke_msg_alloc(id: uint16; dst, src: uint8; length: int): pointer =
  doAssert id == 0x37 and dst == 9 and src == TASK_MM and length == 2
  events.add("allocate")
  if failAllocation: nil else: addr message
proc ke_msg_send(p: pointer) =
  doAssert p == addr message
  doAssert message.psState == 0 and message.staIdx in [5'u8, 6'u8]
  doAssert stations[message.staIdx].psMode == 0
  events.add("send")
proc keMsgHdrFromPayload(p: pointer): pointer = p
proc ke_msg_free(p: pointer) = discard
proc irqSave(): uint32 = 0
proc irqRestore(saved: uint32) = discard
proc staRemovalCurrent(owner: StaQueueIdentity): bool = true
proc mmEnvClearKeepAliveTimestampByte1() = keepalive = keepalive and 0xFFFF00FF'u32
proc apm_tx_int_ps_clear(vif: pointer; index: uint8) =
  doAssert index in [5'u8, 6'u8] and stations[index].psMode == 0
  events.add("ps")
proc mmDeleteSecurityKey(index: uint8): bool =
  keys.add(index)
  true
proc mmDeleteSecurityAddress(index: uint8): bool =
  doAssert index == 2
  events.add("address")
  true
proc staMgmtBeginRemoval(index: uint8; owner: var StaQueueIdentity): pointer =
  doAssert index == 2
  owner = StaQueueIdentity(entry: addr stations[index], vif: stations[index].instNbr)
  addr stations[index]
proc staMgmtFinishRemoval(owner: StaQueueIdentity) =
  doAssert owner.entry == addr stations[2]
  events.add("unregister")
proc setup(vifIndex: uint8) =
  stations = default(typeof(stations))
  vifs = default(typeof(vifs))
  stations[2].instNbr = vifIndex
  for index in 0 .. 1:
    vifs[index].vifIdx = index.uint8
    vifs[index].staIdx = 2
    vifs[index].psBaCounter = 1
    vifs[index].security.staKeySlots = [8'u8, 9, 10, 11]
    stations[index + 5].psMode = 1
  keepalive = 0x12345678
  failAllocation = false
  events.setLen(0)
  keys.setLen(0)
"""

CHECKS = r"""
for vifIndex in 0'u8 .. 1'u8:
  for sleeping in [false, true]:
    for count in 1'u8 .. 3'u8:
      for allocationFails in [false, true]:
        setup(vifIndex)
        vifs[vifIndex].vifType = 2
        vifs[vifIndex].psBaCounter = count
        stations[2].psMode = sleeping.uint8
        failAllocation = allocationFails
        mm_sta_del(2)
        doAssert keepalive == 0x12345678, "station deletion modified keepalive timestamp"
        let lastSleeper = sleeping and count == 1
        doAssert stations[vifIndex + 5].psMode == (if lastSleeper: 0'u8 else: 1'u8)
        doAssert stations[(1 - vifIndex) + 5].psMode == 1
        doAssert vifs[vifIndex].psBaCounter == count - sleeping.uint8
        if lastSleeper:
          doAssert events == (if allocationFails:
            @["allocate", "ps", "address", "unregister"]
          else: @["allocate", "send", "ps", "address", "unregister"])
        else:
          doAssert events == @["address", "unregister"]
        doAssert keys.len == 0

for vifIndex in 0'u8 .. 1'u8:
  for connected in [false, true]:
    for cipher in 0'u8 .. 5'u8:
      for missing in 0 .. 15:
        setup(vifIndex)
        vifs[vifIndex].security.connected = connected.uint8
        vifs[vifIndex].security.cipher = cipher
        var expectedKeys: seq[uint8]
        for slot in 0 .. 3:
          if (missing and (1 shl slot)) != 0:
            vifs[vifIndex].security.staKeySlots[slot] = 0xFF
          elif connected and ((cipher in 2'u8 .. 4'u8 and slot < 3) or
                              (cipher == 1 and slot == 3)):
            expectedKeys.add((slot + 8).uint8)
        mm_sta_del(2)
        doAssert vifs[vifIndex].staIdx == 0xFF
        doAssert keys == expectedKeys
        doAssert events == @["address", "unregister"]
        doAssert keepalive == 0x12345678
"""


@pytest.mark.parametrize("release_mode", [False, True])
def test_station_teardown(release_mode: bool, tmp_path: Path) -> None:
    nim = shutil.which("nim")
    if nim is None:
        pytest.skip("nim is not installed")
    source = (ROOT / "src/bl808/wifi/fw/kernel_mac_channel.nim").read_text()
    path = tmp_path / "station_teardown.nim"
    path.write_text(PLATFORM + procedure(source, "mm_sta_del") + CHECKS)
    command = [nim, "c", "-r", "--skipParentCfg:on", "--skipProjCfg:on",
               "--skipUserCfg:on", f"--nimcache:{tmp_path / 'cache'}", f"-o:{tmp_path / 'test'}"]
    command += ["-d:release", "--checks:off"] if release_mode else ["--checks:on"]
    result = subprocess.run(command + [str(path)], cwd=ROOT, text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    assert result.returncode == 0, result.stdout
