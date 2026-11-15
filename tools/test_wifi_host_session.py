"""Fence production upper TX preparation across VIF/station replacement."""

from pathlib import Path
import shutil
import subprocess

import pytest

from test_wifi_tx_sequence import CHECKS as SEQUENCE_CHECKS, program_source

ROOT = Path(__file__).resolve().parents[1]

CHECKS = r"""
var
  frame, nestedFrame, afterFrame: HostTxDescView
  afterVifs: typeof(vifs)
  afterStations: typeof(sta_info_tab)
  callsAtHook: seq[string]
  hookCalls: int

for phase in ["entry", "ready", "security", "security_trace", "rate", "policy"]:
  when not defined(bl808WifiConnectTrace):
    if phase in ["entry", "security_trace"]: continue
  for vif in 0'u8 .. 1:
    for station in [0'u8, 4, 5, 6]:
      for change in 0 .. 5:
        if change == 1 and station >= 5: continue
        for enabled in [false, true]:
          forbidVifAccess = false
          reset()
          pushResult = 1
          frame = HostTxDescView(vifIdx: vif, staInfoIdx: station, staIdx: 0,
            frameLen: 0x8E88, seqAssigned: 0x1234)
          nestedFrame = HostTxDescView(vifIdx: vif, staInfoIdx: station, staIdx: 1,
            frameLen: 0x8E88)
          calls.setLen(0)
          callsAtHook.setLen(0)
          pushedDesc = nil
          droppedStatus = 0
          hookCalls = 0
          interrupts = enabled
          onStage = proc(stage: string) =
            if stage != phase: return
            doAssert not interrupts
            inc hookCalls
            onStage = nil
            case change
            of 0, 5: inc rxVifEpochs[vif]
            of 1: inc stationEpochs[station]
            of 2: inc rxVifEpochs[vif xor 1]
            of 3: frame.vifIdx = 255
            else: retiringVif = vif.int
            if change != 2:
              vifs[vif].psFlags = 0xA5
              # Reused peer storage is deliberately valid: a validity bit alone
              # cannot distinguish the replacement from the original session.
              staInfoForIdx(station).valid = 1
              staInfoForIdx(station).controlPortState = 2
              for tid in 0 .. 8:
                staTxSequence(staInfoForIdx(station)).seqCounters[tid] = 0x7A5
            else:
              vifs[vif xor 1].psFlags = 0xA5
            if change == 5:
              doAssert txu_cntrl_push(addr nestedFrame, 3)
              doAssert not interrupts
              doAssert pushedDesc == addr nestedFrame
            afterFrame = frame
            afterFrame.staInfoIdx = 255
            afterVifs = vifs
            afterStations = sta_info_tab
            for call in calls: callsAtHook.add(call)
            forbidVifAccess = change != 2

          let accepted = txu_cntrl_push(addr frame, 2)
          forbidVifAccess = false
          doAssert hookCalls == 1 and interrupts == enabled
          if change == 2:
            doAssert accepted and pushedDesc == addr frame
            doAssert droppedStatus == 0
            doAssert vifs[vif xor 1] == afterVifs[vif xor 1]
          else:
            doAssert not accepted
            doAssert droppedStatus == 0xC0020000'u32
            doAssert calls == callsAtHook & @["drop-count", "confirm", "irq-restore"],
              "retired preparation called another stage"
            doAssert vifs == afterVifs, "retired preparation modified a replacement VIF"
            doAssert sta_info_tab == afterStations, "retired preparation modified a replacement peer"
            doAssert frame == afterFrame, "retired preparation continued formatting"
            if change == 5:
              doAssert pushedDesc == addr nestedFrame
            else:
              doAssert pushedDesc == nil

# Capture rejects invalid indices without reading past either identity table.
doAssert not txlCaptureSession(nil).captured
for vif in 0 .. 255:
  for station in 0 .. 255:
    frame = HostTxDescView(vifIdx: vif.uint8, staInfoIdx: station.uint8)
    let identity = txlCaptureSession(addr frame)
    doAssert identity.captured == (vif < 2 and (station < 7 or station == 255))
"""


def run_case(tmp_path: Path, mode: str, mutation: int | None, trace: bool) -> None:
    nim = shutil.which("nim")
    if nim is None:
        pytest.skip("Nim is required")
    body = "var forbidVifAccess = false\n" + program_source().replace(
        "proc vifChannelForIdx(i: uint8): ptr Vif = addr vifs[i]",
        "proc vifChannelForIdx(i: uint8): ptr Vif =\n"
        "  doAssert not forbidVifAccess, \"VIF read after session retirement\"\n"
        "  addr vifs[i]",
    )
    if mutation is not None:
        guard = "  ensureCurrentSession()\n"
        parts = body.split(guard)
        assert len(parts) == 7
        body = guard.join(parts[: mutation + 1]) + parts[mutation + 1]
        if mutation + 2 < len(parts):
            body += guard + guard.join(parts[mutation + 2 :])
    setup = SEQUENCE_CHECKS.split("proc checkTx(", 1)[0]
    source = tmp_path / "host_session.nim"
    source.write_text(body + setup + CHECKS)
    options = {"checked": [], "release": ["-d:release", "--assertions:on"],
               "asan": ["--cc:clang", "--passC:-fsanitize=address", "--passL:-fsanitize=address"]}
    result = subprocess.run([nim, "c", "-r", "--skipParentCfg:on", "--skipProjCfg:on",
        "--skipUserCfg:on", f"--nimcache:{tmp_path / 'cache'}", f"-o:{tmp_path / 'test'}",
        *options[mode], *(["-d:bl808WifiConnectTrace"] if trace else []), str(source)],
        cwd=ROOT, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=90)
    if mutation is None:
        assert result.returncode == 0, result.stdout
    else:
        assert result.returncode != 0 and "AssertionDefect" in result.stdout, result.stdout


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
@pytest.mark.parametrize("mutation", [None, *range(6)])
def test_host_preparation_session(tmp_path: Path, mode: str, mutation: int | None) -> None:
    run_case(tmp_path, mode, mutation, True)


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_host_preparation_session_without_trace(tmp_path: Path, mode: str) -> None:
    run_case(tmp_path, mode, None, False)
