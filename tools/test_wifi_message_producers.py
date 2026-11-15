"""Execute connection-loss and probe message production."""

from pathlib import Path
import shutil
import subprocess

import pytest

from test_wifi_disconnect_tx import procedure


ROOT = Path(__file__).resolve().parents[1]

PLATFORM = r"""
import bl808/wifi/fw_messages
const MAX_VIFS = 2
type
  TxDesc = object
    vifIdx, staInfoIdx: uint8
  Vif = object
    vifIdx, probeCount, staIdx: uint8
    beacon: TxDesc
  Sta = object
    trafficFlags: uint8
    psStatus: uint32
  BcnEnv = object
    pendingCount: uint32
var
  allocation: array[8, uint8]
  messageId: uint16
  destination, source: uint8
  messageLength: uint32
  messageCount: int
  nimFwDbgConnLossInd: uint32
  envStorage: BcnEnv
  stas: array[7, Sta]
  pushResult: uint8
  postponedCalls: int
  expectedVif: pointer
  vifs: array[MAX_VIFS, Vif]
  rxVifEpochs: array[MAX_VIFS, uint32]
  interrupts = true
proc vifChannelAt(p: pointer): ptr Vif = cast[ptr Vif](p)
proc vifChannelForIdx(i: uint8): ptr Vif = addr vifs[i]
proc staDeleteEpoch(i: uint8): uint32 = 0
proc irqSave(): uint32 =
  result = interrupts.uint32 * 8
  interrupts = false
proc irqRestore(saved: uint32) = interrupts = (saved and 8) != 0
proc vifApBeaconFrameDesc(vif: ptr Vif): ptr TxDesc = addr vif.beacon
proc staInfoForIdx(i: uint8): ptr Sta = addr stas[i]
proc ke_msg_alloc(id: uint16; dst, src: uint8; size: uint32): pointer =
  messageId = id
  destination = dst
  source = src
  messageLength = size
  for value in allocation.mitems: value = 0xA5
  addr allocation[0]
proc ke_msg_send(p: pointer) =
  doAssert p == addr allocation[0]
  inc messageCount
proc ke_msg_free_payload(p: pointer) = discard
proc txl_frame_push(p: pointer; ac: uint8): uint8 =
  let vif = vifChannelAt(expectedVif)
  doAssert p == cast[pointer](addr vif.beacon) and ac == 4
  doAssert vif.beacon.vifIdx == vif.vifIdx and vif.beacon.staInfoIdx == 255
  pushResult
proc sta_mgmt_send_postponed_frame(vif, sta: pointer; budget: uint32): uint32 =
  doAssert vif == expectedVif and budget == 0
  doAssert cast[ptr Sta](sta).psStatus == 9
  inc postponedCalls
  0
proc reset() =
  messageCount = 0
  messageId = 0
  destination = 0
  source = 0
  postponedCalls = 0
  envStorage.pendingCount = 5
  stas = default(typeof(stas))
"""

CHECKS = r"""
for index in [0'u8, 1]:
  for reason in [0'u16, 16, 21, 22, 65535]:
    reset()
    vifs[index] = Vif(vifIdx: index)
    mm_send_connection_loss_ind(addr vifs[index], reason)
    doAssert messageCount == 1 and messageId == 49
    doAssert destination == 4 and source == 0 and messageLength == 4
    doAssert allocation[0] == (reason and 255).uint8
    doAssert allocation[1] == (reason shr 8).uint8 and allocation[2] == index

for index in [5'u8, 255]:
  reset()
  vifs[0] = Vif(vifIdx: index)
  mm_send_connection_loss_ind(addr vifs[0], 22)
  mm_send_connection_loss_ind(nil, 22)
  doAssert messageCount == 0

for status in [0'u32, 1, 0x800000, 0x80800000'u32]:
  reset()
  vifs[1] = Vif(vifIdx: 1, probeCount: 7)
  let vif = addr vifs[1]
  mm_ap_probe_cfm(vif, status)
  if (status and 0x800000) != 0:
    doAssert messageCount == 0 and vif.probeCount == 0
  else:
    doAssert messageCount == 1 and messageId == 49 and destination == 4
    doAssert allocation[0] == 16 and allocation[2] == 1
    doAssert vif.probeCount == 7

"""


def test_message_producers_use_vendor_wire_contracts(tmp_path: Path) -> None:
    nim = shutil.which("nim")
    if nim is None:
        pytest.skip("Nim is required")
    base = ROOT / "src/bl808/wifi/fw"
    kernel = (base / "kernel_mac_channel.nim").read_text()
    layout = (base / "layout_types.nim").read_text()
    types = "type\n"
    for name in ["MmConnectionLossIndPayload", "MmTrafficReqIndPayload", "MmVifIdentity"]:
        types += "  " + name + layout.split("  " + name, 1)[1].split("\n\n  ", 1)[0] + "\n"
    types += "const\n  MmConnectionLossIndPayloadSize = sizeof(MmConnectionLossIndPayload).uint32\n"
    types += "  MmTrafficReqIndPayloadSize = sizeof(MmTrafficReqIndPayload).uint32\n"
    helpers = procedure(kernel, "mmCaptureVif") + procedure(kernel, "mmVifCurrent")
    loss = "proc mm_send_connection_loss_ind*" + kernel.split(
        "proc mm_send_connection_loss_ind*", 1
    )[1].split("\nproc mm_ps_change_ind*", 1)[0]
    probe = "proc mm_ap_probe_cfm*" + kernel.split("proc mm_ap_probe_cfm*", 1)[1].split(
        "\nproc mm_bcn_transmitted*", 1
    )[0]
    program = tmp_path / "message_producers.nim"
    program.write_text(PLATFORM + types + helpers + loss + probe + CHECKS)
    result = subprocess.run(
        [nim, "c", "-r", "--skipParentCfg:on", "--skipProjCfg:on", "--skipUserCfg:on",
         f"--path:{ROOT / 'src'}", f"--nimcache:{tmp_path / 'nimcache'}", "--checks:on",
         f"-o:{tmp_path / 'test'}", str(program)],
        cwd=ROOT, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
    )
    assert result.returncode == 0, result.stdout
