"""Keep TIM notifications bound to the AP station that requested them."""

from pathlib import Path
import re
import shutil
import subprocess

import pytest

from test_wifi_disconnect_tx import procedure
from test_wifi_ps_postpone import PLATFORM as PS_PLATFORM

ROOT = Path(__file__).resolve().parents[1]
FW = ROOT / "src/bl808/wifi/fw"

PLATFORM = PS_PLATFORM.replace("var\n", "var\n  onAllocate, onDrain: proc()\n  allocations, drains: int\n  failAllocation: bool\n", 1)
PLATFORM = PLATFORM.replace(procedure(PLATFORM, "ke_msg_alloc"), r"""
proc ke_msg_alloc(id: uint16; dest, src: uint8; size: uint32): pointer =
  doAssert not interrupts
  doAssert id == 47 and dest == 0 and src == 3 and size == 4
  inc allocations
  if onAllocate != nil: onAllocate()
  if failAllocation: return nil
  allocated = default(MmTimUpdatePayload)
  addr allocated
""")
PLATFORM += r"""
proc sta_mgmt_send_postponed_frame(vif, sta: pointer; count: uint32): uint32 =
  doAssert not interrupts
  doAssert vif == (addr vifs[1]) and sta == (addr stas[2]) and count == 0
  inc drains
  if onDrain != nil: onDrain()
  0
"""

CHECKS = r"""
var frame: TestTxFrame
var changedStation: Sta
var changedVif: Vif

proc setup(clear: bool; station = 2'u8) =
  reset()
  allocations = 0
  drains = 0
  failAllocation = false
  onAllocate = nil
  onDrain = nil
  vifs[1].vifType = VIF_TYPE_AP
  stas[station] = Sta(instNbr: 1, aid: 42, valid: (station < 5).uint8,
    trafficFlags: (if clear: 2'u8 else: 0'u8))
  frame = TestTxFrame(vifIdx: 1, staIdx: station,
    accessCategory: 0, postponeFlags: 0x1000)

proc mutate(kind: int) =
  case kind
  of 0: inc rxVifEpochs[1]
  of 1: inc stationEpochs[2]
  of 2: stas[2].aid = 71
  of 3: stas[2].instNbr = 0
  of 4: stas[2].valid = 0
  of 5: vifs[1].vifType = VIF_TYPE_STA
  of 6: inc rxVifEpochs[0]
  else: stas[2].trafficFlags = 0x08
  changedStation = stas[2]
  changedVif = vifs[1]

for clear in [false, true]:
  for initiallyEnabled in [false, true]:
    for kind in 0 .. 7:
      setup(clear)
      interrupts = initiallyEnabled
      onAllocate = proc() = mutate(kind)
      if clear: apm_tx_int_ps_clear(addr vifs[1], 2)
      else: apm_tx_int_ps_postpone(addr frame, addr stas[2])
      doAssert interrupts == initiallyEnabled
      doAssert stas[2] == changedStation and vifs[1] == changedVif
      doAssert allocations == 1
      if kind == 6:
        doAssert frees == 0 and messages.len == 1
        doAssert messages[0] == MmTimUpdatePayload(aid: 42, vifIdx: 1,
          setFlag: (if clear: 0'u8 else: 1'u8))
      else:
        doAssert frees == 1 and messages.len == 0,
          "obsolete TIM request escaped allocation"

# Clear must revalidate before reading or changing the station after draining.
for kind in 0 .. 6:
  setup(true)
  onDrain = proc() = mutate(kind)
  apm_tx_int_ps_clear(addr vifs[1], 2)
  doAssert drains == 1 and interrupts
  if kind == 6:
    doAssert stas[2].trafficFlags == 0 and messages.len == 1
  else:
    doAssert stas[2] == changedStation and vifs[1] == changedVif
    doAssert allocations == 0 and messages.len == 0

# Unrelated host traffic does not suppress an internal TIM set, but it does
# prevent a stale TIM clear from erasing a newly populated bitmap bit.
for clear in [false, true]:
  setup(clear)
  onAllocate = proc() = stas[2].trafficFlags = stas[2].trafficFlags or 1
  if clear: apm_tx_int_ps_clear(addr vifs[1], 2)
  else: apm_tx_int_ps_postpone(addr frame, addr stas[2])
  doAssert messages.len == (if clear: 0 else: 1)
  doAssert frees == clear.int
  doAssert stas[2].trafficFlags == (if clear: 1'u8 else: 3'u8)

# Allocation failure changes no ownership and never frees or sends a null message.
for clear in [false, true]:
  setup(clear)
  failAllocation = true
  if clear: apm_tx_int_ps_clear(addr vifs[1], 2)
  else: apm_tx_int_ps_postpone(addr frame, addr stas[2])
  doAssert allocations == 1 and frees == 0 and messages.len == 0
  doAssert stas[2].trafficFlags == (if clear: 0'u8 else: 2'u8)
  doAssert interrupts

# Broadcast/multicast station slots are valid without the ordinary valid byte.
for index in [5'u8, 6'u8]:
  setup(false, index)
  apm_tx_int_ps_postpone(addr frame, addr stas[index])
  doAssert messages.len == 1 and allocations == 1 and frees == 0

# Ignore mismatched frames, invalid ACs, and pointers outside the station table.
for kind in 0 .. 7:
  setup(false)
  var target = cast[pointer](addr stas[2])
  case kind
  of 0: frame.vifIdx = 0
  of 1: frame.staIdx = 1
  of 2: frame.accessCategory = 4
  of 3: frame.accessCategory = 255
  of 4: target = nil
  of 5: target = cast[pointer](1)
  of 6: stas[2].valid = 0
  else: stas[2].instNbr = 255
  apm_tx_int_ps_postpone(addr frame, target)
  doAssert allocations == 0 and messages.len == 0 and frees == 0
  doAssert stas[2].trafficFlags == 0 and interrupts
setup(false)
apm_tx_int_ps_postpone(nil, addr stas[2])
apm_tx_int_ps_clear(nil, 2)
apm_tx_int_ps_clear(addr vifs[1], 255)
doAssert allocations == 0 and drains == 0 and interrupts
setup(true)
vifs[0].vifType = VIF_TYPE_AP
apm_tx_int_ps_clear(addr vifs[0], 2)
doAssert allocations == 0 and drains == 0 and stas[2].trafficFlags == 2
"""


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
@pytest.mark.parametrize("mutation", [None, "allocation", "drain", "vif_epoch", "station_epoch", "traffic", "binding", "irq"])
def test_ps_notification_lifetime(tmp_path: Path, mode: str, mutation: str | None) -> None:
    nim = shutil.which("nim")
    if nim is None:
        pytest.skip("Nim is required")
    apm = (FW / "scan_station_ap_me.nim").read_text()
    source = "".join(procedure(apm, name) for name in [
        "apmPsCapture", "apmPsSessionCurrent", "apmPsTimRequest",
        "apm_tx_int_ps_postpone", "apm_tx_int_ps_clear",
    ])
    if mutation == "allocation":
        old = ("  if not apmPsSessionCurrent(identity) or\n"
               "      (setFlag == 0 and\n"
               "       (staInfoForIdx(identity.station).trafficFlags and clearMask) != 0) or\n"
               "      (setFlag != 0 and\n"
               "       (staInfoForIdx(identity.station).trafficFlags and requiredTraffic) == 0):")
        assert old in source
        source = source.replace(old, "  if false:")
    elif mutation == "drain":
        old = ("  discard sta_mgmt_send_postponed_frame(vifEntry, cast[pointer](sta), 0)\n"
               "  if not apmPsSessionCurrent(identity):\n    return\n")
        assert old in source
        source = source.replace(old, old.split("\n  if not ", 1)[0] + "\n")
    elif mutation == "vif_epoch":
        source = source.replace("rxVifEpochs[identity.vif] != identity.vifEpoch", "false")
    elif mutation == "station_epoch":
        source = source.replace("staDeleteEpoch(identity.station) != identity.stationEpoch", "false")
    elif mutation == "traffic":
        source = source.replace("(setFlag == 0 and\n       (staInfoForIdx(identity.station).trafficFlags and clearMask) != 0)", "false").replace(
            "(setFlag != 0 and\n       (staInfoForIdx(identity.station).trafficFlags and requiredTraffic) == 0)", "false")
    elif mutation == "binding":
        old = "tx.vifIdx != identity.vif or tx.staIdx != identity.station or\n      "
        assert old in source
        source = source.replace(old, "")
    elif mutation == "irq":
        source = source.replace("  let saved = irqSave()\n  defer: irqRestore(saved)\n", "")
    layout = (FW / "layout_types.nim").read_text()
    identity = "type\n  ApmPsSession = object" + layout.split(
        "  ApmPsSession = object", 1
    )[1].split("\n  TxDmaOwner", 1)[0]
    storage = (FW / "global_state/storage.nim").read_text()
    table = "\nvar mac_ac2uapsd*" + storage.split("var mac_ac2uapsd*", 1)[1].split("\n]", 1)[0] + "\n]\n"
    program = tmp_path / "ps_lifetime.nim"
    program.write_text(PLATFORM + identity + table + source + CHECKS)
    options = {"checked": [], "release": ["-d:release", "--assertions:on"],
        "asan": ["--cc:clang", "--passC:-fsanitize=address", "--passL:-fsanitize=address"]}
    result = subprocess.run([nim, "c", "-r", "--skipParentCfg:on", "--skipProjCfg:on", "--skipUserCfg:on",
        f"--path:{ROOT / 'src'}", f"--nimcache:{tmp_path / 'cache'}", f"-o:{tmp_path / 'test'}",
        *options[mode], str(program)], cwd=ROOT, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=120)
    if mutation is None:
        assert result.returncode == 0, result.stdout
    else:
        assert result.returncode != 0 and "AssertionDefect" in result.stdout, result.stdout
