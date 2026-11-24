"""Pinned TX frame offsets and the internal completion ownership path."""

import json
from pathlib import Path
import re
import shutil
import subprocess

import pytest

from test_wifi_disconnect_tx import FW, ROOT, procedure
from test_wifi_tx_session import PLATFORM


ARCHIVE = ROOT / "src/bl808/libwifi_fw.a"
SYMBOLS = {
    "txl_frame_get": (0x080002AC, 250),
    "txl_frame_push": (0x080003D0, 130),
    "txl_frame_cfm": (0x080004C2, 38),
    "txl_frame_release": (0x080004E8, 70),
    "txl_frame_evt": (0x0800052E, 150),
}
OPS = {
    0x080002F6: "lw s0, 112(a0)",
    0x080002F8: "lw s3, 108(a0)",
    0x08000304: "sw s2, 28(s0)",
    0x0800030E: "sw a5, 24(s0)",
    0x08000346: "sw zero, 208(s1)",
    0x0800034A: "sw zero, 212(s1)",
    0x080003E0: "lw a5, 20(s0)",
    0x08000418: "lbu a5, 0(a3)",
    0x08000424: "sw zero, 56(s0)",
    0x08000442: "lbu a5, 4(a3)",
    0x0800044E: "sw a5, 56(s0)",
    0x0800057A: "lw a5, 80(s2)",
    0x08000584: "lw a5, 208(s0)",
    0x08000590: "lw a1, 64(a4)",
    0x08000594: "lbu a5, 218(s0)",
    0x080005A0: "lbu a5, 216(s0)",
}
RELOCS = {
    0x080002EA: "co_list_pop_front",
    0x0800032A: "tpc_get_vif_tx_power_vs_rate",
    0x0800043A: "txl_cntrl_push_int",
    0x080004D0: "co_list_push_back",
    0x080004E0: "ke_evt_set",
    0x08000566: "co_list_pop_front",
    0x080005AA: "co_list_push_back",
}


def test_pinned_txl_frame_instructions(tmp_path: Path) -> None:
    ar = shutil.which("llvm-ar")
    r2 = shutil.which("r2")
    if ar is None or r2 is None:
        pytest.skip("llvm-ar and radare2 are required")
    member = subprocess.run(
        [ar, "p", str(ARCHIVE), "txl_frame.o"], check=True, capture_output=True
    ).stdout
    obj = tmp_path / "txl_frame.o"
    obj.write_bytes(member)
    symbols = json.loads(subprocess.run(
        [r2, "-q", "-c", "isj", str(obj)], check=True, capture_output=True,
        text=True
    ).stdout)
    exported = {entry["name"]: (entry["vaddr"], entry["size"])
                for entry in symbols if entry["type"] == "FUNC"}
    for name, expected in SYMBOLS.items():
        assert exported[name] == expected

    instructions = {}
    for name in SYMBOLS:
        decoded = json.loads(subprocess.run(
            [r2, "-q", "-e", "bin.relocs.apply=true", "-c",
             f"pDj {SYMBOLS[name][1]} @ sym.{name}", str(obj)],
            check=True, capture_output=True, text=True
        ).stdout)
        instructions.update((op["addr"], op["opcode"]) for op in decoded)
    for offset, opcode in OPS.items():
        assert instructions[offset] == opcode, f"vendor opcode changed at {offset:#x}"
    relocs = json.loads(subprocess.run(
        [r2, "-q", "-c", "irj", str(obj)], check=True, capture_output=True,
        text=True
    ).stdout)
    targets = {entry["vaddr"]: entry["name"] for entry in relocs}
    for offset, target in RELOCS.items():
        assert targets[offset] == target, f"vendor call changed at {offset:#x}"


FUNCTIONS = (
    "txl_frame_desc_index", "txlCaptureFrameIdentity", "txlFrameBeginLease",
    "txlFrameEndLease", "txlFrameLeaseToken", "txlFrameLeaseMatches",
    "txlFrameIdentityCurrent", "txlFrameSessionCurrent",
    "txlCaptureFrameCallback", "txlFrameCallbackCurrent",
    "txlInvokeFrameCallback", "txl_frame_free_list_pop", "txl_frame_get",
    "txl_frame_cfm", "txl_frame_release", "txlFrameConfirmPending",
    "txl_frame_evt",
)

CHECKS = r"""
proc completed(arg: pointer; status: uint32) {.cdecl.} =
  doAssert interruptsEnabled
  inc callbacks
  statuses.add(status)
  if callbacks == 1 and retry:
    let desc = hostTxDescAt(arg)
    desc.retryFlag = 1
    hostTxHwDescAt(desc.hwDesc).confirmStatus = 0x99887766'u32
    inc txEnv.packetCounter
    co_list_push_back(addr frameEnv.usedList, addr desc.link)

for shouldRetry in [false, true]:
  setup()
  retry = shouldRetry
  let frame = hostTxDescAt(txl_frame_get(24))
  frame.vifIdx = 0
  frame.staInfoIdx = 255
  frame.callback = cast[pointer](completed)
  frame.callbackArg = frame
  hostTxHwDescAt(frame.hwDesc).confirmStatus = 0x81234567'u32
  txEnv.packetCounter = 1
  txl_frame_cfm(frame)
  doAssert frameEnv.usedList.first == addr frame.link
  doAssert frameEnv.freeList.first != addr frame.link
  doAssert eventBits == 0x80000'u32
  txl_frame_evt()
  doAssert callbacks == (if shouldRetry: 2 else: 1)
  doAssert statuses == (if shouldRetry:
    @[0x81234567'u32, 0x99887766'u32] else: @[0x81234567'u32])
  doAssert txEnv.packetCounter == 0 and frame.retryFlag == 0
  doAssert frameEnv.usedList.first == nil and eventBits == 0
  doAssert co_list_cnt(addr frameEnv.freeList) == 4
  doAssert interruptsEnabled
"""


@pytest.mark.parametrize("release", [False, True])
def test_internal_completion_handoff(tmp_path: Path, release: bool) -> None:
    nim = shutil.which("nim")
    if nim is None:
        pytest.skip("Nim is required")
    tx = (FW / "tx_layer.nim").read_text()
    functions = "".join(procedure(tx, name) for name in FUNCTIONS)
    debug = "\nvar\n" + "".join(
        f"  {name}: uint32\n" for name in sorted(set(re.findall(r"\bnimFwDbg\w+", functions)))
    )
    platform = PLATFORM.replace("proc ke_evt_clear(bits: uint32) = discard", "")
    platform = platform.replace("proc ke_evt_set(bits: uint32) = discard", "")
    platform += """
var eventBits: uint32
var retry: bool
proc ke_evt_clear(bits: uint32) = eventBits = eventBits and not bits
proc ke_evt_set(bits: uint32) = eventBits = eventBits or bits
"""
    source = tmp_path / "txl_parity.nim"
    source.write_text(platform + debug + functions + CHECKS)
    command = [nim, "c", "-r", "--skipParentCfg:on", "--skipProjCfg:on",
               "--skipUserCfg:on", "--checks:on"]
    if release:
        command.append("-d:release")
    command += [f"--nimcache:{tmp_path / 'nimcache'}",
                f"-o:{tmp_path / 'test'}", str(source)]
    result = subprocess.run(
        command, cwd=ROOT,
        text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT
    )
    assert result.returncode == 0, result.stdout
