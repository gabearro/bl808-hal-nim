"""Exercise actual RX session stamps through the deferred upload handler."""

from pathlib import Path
import shutil
import subprocess

import pytest

from test_wifi_disconnect_tx import procedure
from test_wifi_rx_upload import PLATFORM as UPLOAD_PLATFORM

ROOT = Path(__file__).resolve().parents[1]
FW = ROOT / "src/bl808/wifi/fw"

PLATFORM = UPLOAD_PLATFORM.replace(
    "proc rxStationCurrent(p: pointer): bool = true\n", ""
) + r"""
const STA_INFO_TAB_ENTRIES = 7
const MAX_VIFS = 2
type
  RxStationIdentity = object
    epoch: uint32
    vifEpochs: array[MAX_VIFS, uint32]
    keyRevision: uint64
    station, vif: uint8
    captured, associated: bool
  Sta = object
    valid, instNbr: uint8
var
  stations: array[7, Sta]
  epochs: array[7, uint32]
  descriptors: array[3, RxMpduDescView]
  headers: array[3, RxSwDescView]
  payloads: array[3, RxPayloadHwDescView]
  rxStationIdentities: array[41, RxStationIdentity]
  rxUploadEpochs: array[41, uint32]
  rxVifEpochs: array[MAX_VIFS, uint32]
  rxKeyRevision = 1'u64
  captureInterrupts = true
proc rxMpduDescIndex(p: pointer): int =
  for i in 0 ..< descriptors.len:
    if p == cast[pointer](addr descriptors[i]): return i
  -1
proc staInfoForIdx(i: uint8): ptr Sta = addr stations[i]
proc staDeleteEpoch(i: uint8): uint32 = epochs[i]
proc irqSave(): uint32 =
  result = captureInterrupts.uint32 * 8
  captureInterrupts = false
proc irqRestore(saved: uint32) = captureInterrupts = (saved and 8) != 0
"""

CHECKS = r"""
proc resetSession() =
  upper = default(RxuEnv)
  lower = default(RxlEnv)
  stations = default(typeof(stations))
  descriptors = default(typeof(descriptors))
  headers = default(typeof(headers))
  payloads = default(typeof(payloads))
  rxStationIdentities = default(typeof(rxStationIdentities))
  calls.setLen(0)
  freed.setLen(0)
  capturedNode = nil
  inputResult = 0
  stations[3] = Sta(valid: 1, instNbr: 0)
  stations[4] = Sta(valid: 1, instNbr: 1)
  for i in 0 ..< descriptors.len:
    descriptors[i].swDesc = addr headers[i]
    descriptors[i].descFlag = 3
    headers[i].mpduLengthBytes = 100
    headers[i].bufferChain = addr payloads[i]
    payloads[i].bufferAddr = 0x22000000'u32 + i.uint32 * 0x800
    rxCaptureStation(addr descriptors[i], 0x02006000'u32 or (12'u32 shl 15))

for invalidation in 0 .. 4:
  resetSession()
  upper.uploadList.nodes.add(addr descriptors[0])
  case invalidation
  of 0: inc epochs[4]
  of 1: stations[4].valid = 0
  of 2: stations[4].instNbr = 0
  of 3: inc rxVifEpochs[1]
  else: rxStationIdentities = default(typeof(rxStationIdentities))
  rxu_swdesc_upload_evt()
  doAssert calls == @["clear", "free"]
  doAssert freed == @[cast[pointer](addr descriptors[0])]
  doAssert capturedNode == nil and payloads[0].usedFlag == 0
  doAssert headers[0].uploadDone == 0 and descriptors[0].descCount == 0
  doAssert lower.uploadCount == 0

# Reuse invalidates only the old station; fresh capture and another peer survive.
resetSession()
inc epochs[4]
rxCaptureStation(addr descriptors[1], 0x02006000'u32 or (12'u32 shl 15))
rxCaptureStation(addr descriptors[2], 0x02006000'u32 or (11'u32 shl 15))
for i in 0 ..< descriptors.len: upper.uploadList.nodes.add(addr descriptors[i])
rxu_swdesc_upload_evt()
doAssert payloads[0].usedFlag == 0 and headers[0].uploadDone == 0
doAssert payloads[1].usedFlag == 1 and headers[1].uploadDone == 1
doAssert payloads[2].usedFlag == 1 and headers[2].uploadDone == 1
doAssert calls.count("input") == 2
when defined(bl808WifiRxPbufInput):
  doAssert freed.len == 3 and lower.uploadCount == 0
else:
  doAssert freed == @[cast[pointer](addr descriptors[0])] and lower.uploadCount == 2

# A descriptor captured while its station was invalid cannot become valid later.
resetSession()
stations[4].valid = 0
rxCaptureStation(addr descriptors[0], 0x02006000'u32 or (12'u32 shl 15))
stations[4].valid = 1
upper.uploadList.nodes.add(addr descriptors[0])
rxu_swdesc_upload_evt()
doAssert capturedNode == nil and freed.len == 1
"""


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
@pytest.mark.parametrize("pbuf_input", [False, True])
def test_rx_session_upload(tmp_path: Path, mode: str, pbuf_input: bool) -> None:
    nim = shutil.which("nim")
    if nim is None:
        pytest.skip("Nim is required")
    lower = (FW / "rx_layer.nim").read_text()
    source = "import std/sequtils\n" + PLATFORM
    for name in ["rxCaptureStation", "rxIdentityCurrent", "rxStationCurrent"]:
        source += procedure(lower, name)
    source += procedure((FW / "rx_upper.nim").read_text(), "rxu_swdesc_upload_evt")
    # The upload routine's debug counters are already declared by the base fixture.
    path = tmp_path / "rx_session.nim"
    path.write_text(source + CHECKS)
    options = {"checked": [], "release": ["-d:release", "--assertions:on"],
               "asan": ["--cc:clang", "--passC:-fsanitize=address", "--passL:-fsanitize=address"]}
    if pbuf_input:
        options[mode].append("-d:bl808WifiRxPbufInput")
    result = subprocess.run([nim, "c", "-r", "--skipParentCfg:on", "--skipProjCfg:on",
        "--skipUserCfg:on", f"--nimcache:{tmp_path / 'cache'}", f"-o:{tmp_path / 'test'}",
        *options[mode], str(path)], cwd=ROOT, text=True,
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=90)
    assert result.returncode == 0, result.stdout
