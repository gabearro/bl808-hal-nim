"""Execute association confirmation and the successful supplicant transition."""

from pathlib import Path
import re
import shutil
import subprocess

import pytest


ROOT = Path(__file__).resolve().parents[1]
FW = ROOT / "src/bl808/wifi/fw"

PLATFORM = r"""
proc smCleanupConsumeReply(reply: pointer): bool = false
const
  MAX_VIFS = 2
  STA_INFO_TAB_ENTRIES = 7
  TASK_SM = 4'u8
  TASK_MM = 0'u8
  TASK_ME = 3'u8
  SM_ACTIVATING_STATE = 9'u8
  SmDisconnectingState = 10'u8
  MM_SET_PS_OPTIONS_REQ = 57'u16
  ME_SET_PS_DISABLE_REQ = 0xC0F'u16
type
  MmSetPsOptionsReqPayload = object
    vifIdx: uint8
    listenInterval: uint16
    options: uint8
  MeSetPsDisableReqPayload = object
    disable, vifIdx: uint8
  Sta = object
    valid, instNbr, controlPortState: uint8
    rateWord: uint16
  Vif = object
    staIdx: uint8
    key: tuple[flags: uint32]
    security: tuple[cipher: uint8]
  ConnectInfo = object
    vifIdx, psOptions: uint8
    listenInterval, ctrlPortEthertype: uint16
var
  stations: array[7, Sta]
  vifs: array[2, Vif]
  request: ConnectInfo
  sm: tuple[connectInfo: pointer]
  mm: tuple[rxPromiscUploadFlag: uint8, rxFilterBase: uint32]
  nimFwWpaPendingMask: uint32
  state = SM_ACTIVATING_STATE
  options: MmSetPsOptionsReqPayload
  disable: MeSetPsDisableReqPayload
  allocations, messages, connected, stationReady, filterUpdates: int
  allocationFails: bool
const
  MmSetPsOptionsReqPayloadSize = sizeof(MmSetPsOptionsReqPayload).uint32
  MeSetPsDisableReqPayloadSize = sizeof(MeSetPsDisableReqPayload).uint32
proc staInfoForIdx(index: uint8): ptr Sta = addr stations[index]
proc vifChannelForIdx(index: uint8): ptr Vif = addr vifs[index]
proc vifKeyPointers(vif: ptr Vif): ptr tuple[flags: uint32] = addr vif.key
proc vifSecurity(vif: ptr Vif): ptr tuple[cipher: uint8] = addr vif.security
proc connectInfoView(p: pointer): ptr ConnectInfo = cast[ptr ConnectInfo](p)
proc smEnvView(): ptr typeof(sm) = addr sm
proc mmEnvView(): ptr typeof(mm) = addr mm
proc ke_state_get(task: uint8): uint8 = state
proc ke_msg_alloc(id: uint16; dst, src: uint8; size: uint32): pointer =
  inc allocations
  if allocationFails: return nil
  if id == MM_SET_PS_OPTIONS_REQ:
    doAssert dst == TASK_MM and src == TASK_SM
    doAssert size == MmSetPsOptionsReqPayloadSize
    cast[pointer](addr options)
  else:
    doAssert id == ME_SET_PS_DISABLE_REQ and dst == TASK_ME and src == TASK_SM
    doAssert size == MeSetPsDisableReqPayloadSize
    cast[pointer](addr disable)
proc ke_msg_send(p: pointer) = inc messages
proc mm_rx_filter_set() = inc filterUpdates
proc sm_connection_sta_add_ind(p: pointer) = inc stationReady
proc sm_connect_ind(status, reason: uint16) =
  doAssert status == 0 and reason == 0
  inc connected
template nimFwConnectTrace2U32(args: varargs[untyped]) = discard
proc reset(vif, sta: uint8) =
  stations = default(typeof(stations))
  vifs = default(typeof(vifs))
  request = ConnectInfo(vifIdx: vif, listenInterval: 17, psOptions: 3,
                        ctrlPortEthertype: 0x8E88)
  sm.connectInfo = addr request
  vifs[vif].staIdx = sta
  stations[sta] = Sta(valid: 1, instNbr: vif)
  nimFwWpaPendingMask = 0
  state = SM_ACTIVATING_STATE
  allocations = 0
  messages = 0
  connected = 0
  stationReady = 0
  filterUpdates = 0
  allocationFails = false
"""

CHECKS = r"""
for vif in 0'u8 .. 1'u8:
  for sta in 0'u8 .. 6'u8:
    for mask in 0'u32 .. 3'u32:
      for cipher in 0'u8 .. 4'u8:
        for flags in 0'u32 .. 3'u32:
          reset(vif, sta)
          nimFwWpaPendingMask = mask
          vifs[vif].security.cipher = cipher
          vifs[vif].key.flags = flags
          mm_set_vif_state_cfm_handler(nil)
          let pending = cipher >= 2 and (mask and (1'u32 shl vif)) != 0
          let expectedPort = if pending: 1'u8 else: 2'u8 - (flags and 1).uint8
          doAssert stations[sta].controlPortState == expectedPort,
            "association opened a port before WPA completion"
          doAssert stations[sta].rateWord == 0x888E
          doAssert filterUpdates == 1 and stationReady == 1
          doAssert allocations == (if (flags and 1) == 0: 2 else: 1)
          doAssert connected == (if cipher <= 1: 1 else: 0)
          if pending:
            # Execute the production success path after association. The full
            # failure and duplicate-result paths are covered by supplicant tests.
            sm_handle_supplicant_result(sta, 0)
            doAssert stations[sta].controlPortState == 2 and connected == 1
            sm_handle_supplicant_result(sta, 0)
            doAssert connected == 1

for corruption in 0 .. 4:
  reset(0, 0)
  case corruption
  of 0: request.vifIdx = 255
  of 1: vifs[0].staIdx = 255
  of 2: stations[0].valid = 0
  of 3: stations[0].instNbr = 1
  else: sm.connectInfo = nil
  mm_set_vif_state_cfm_handler(nil)
  doAssert allocations == 0 and stationReady == 0 and connected == 0

reset(0, 0)
nimFwWpaPendingMask = 1
vifs[0].security.cipher = 3
allocationFails = true
mm_set_vif_state_cfm_handler(nil)
doAssert stations[0].controlPortState == 1 and connected == 0
"""


@pytest.mark.parametrize("release", [False, True])
def test_association_keeps_wpa_port_restricted(tmp_path: Path, release: bool) -> None:
    nim = shutil.which("nim")
    if nim is None:
        pytest.skip("Nim is required")
    handlers = (FW / "task_handlers.nim").read_text()
    station = (FW / "scan_station_ap_me.nim").read_text()
    layout = (FW / "layout_types.nim").read_text()
    association = re.search(
        r"(?ms)^proc mm_set_vif_state_cfm_handler\*.*?(?=^proc )", handlers
    ).group(0)
    success = "proc sm_handle_supplicant_result*" + station.split(
        "proc sm_handle_supplicant_result*", 1
    )[1].split("\n  if reason == 15:", 1)[0] + "\n"
    gate = "proc lmacGateHalfword" + layout.split("proc lmacGateHalfword", 1)[1].split(
        "\nproc ", 1
    )[0]
    debug = "\nvar\n" + "".join(
        f"  {name}: uint32\n" for name in sorted(set(re.findall(
            r"\bnimFwDbg\w+", association + success
        )))
    )
    source = tmp_path / "control_port.nim"
    source.write_text(PLATFORM + debug + gate + association + success + CHECKS)
    command = [nim, "c", "-r", "--skipParentCfg:on", "--skipProjCfg:on", "--skipUserCfg:on",
               f"--nimcache:{tmp_path / 'cache'}", f"-o:{tmp_path / 'test'}"]
    if release:
        command += ["-d:release", "--assertions:on"]
    result = subprocess.run(command + [str(source)], cwd=ROOT, text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    assert result.returncode == 0, result.stdout
