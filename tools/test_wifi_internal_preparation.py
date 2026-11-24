"""Exercise internal TX preparation across retirement and slot reuse."""

from pathlib import Path
import re
import shutil
import subprocess

import pytest

from test_wifi_disconnect_tx import procedure
from test_wifi_tx_session import PLATFORM as SESSION_PLATFORM

ROOT = Path(__file__).resolve().parents[1]
FW = ROOT / "src/bl808/wifi/fw"


def platform_source() -> str:
    source = SESSION_PLATFORM.replace(
        "vifIdx, staInfoIdx: uint8", "vifIdx, staInfoIdx, staIdx: uint8"
    ).replace(
        "    rateTemplate: array[52, uint8]",
        "    headerThd: tuple[magic: uint32]\n    rateTemplate: array[52, uint8]",
    ).replace("type\n", """type
  TxSessionIdentity = object
    vifEpoch, stationEpoch, resetEpoch: uint32
    vif, station: uint8
    captured: bool
  ChannelContext = object
    status, contextIndexOrMarker, altIdx: uint8
  TxVif = object
    chanCtxt: ptr ChannelContext
    vifIdx: uint8
  ChannelEnv = object
    currentCtxt, scheduledCtxt: ptr ChannelContext
    flags, ctxtCount: uint8
""", 1) + """\nvar
  vifs: array[2, TxVif]
  channel: ChannelEnv
  context: ChannelContext
  tails: array[5, pointer]
  step, stopAt, change, selectedAc, profile: int
  watching, fired, drainReuse: bool
  drainCalls, postponeCalls: int
  held: array[4, ptr HostTxDescView]
  replacementFrame: ptr HostTxDescView
  replacementSnapshot: HostTxDescView
  replacementHardware: HwDesc
  replacementLink: LinkDesc
  incomingIrq: bool
"""
    for name in ["txl_int_fake_transfer", "txl_payload_handle_backup", "nimFwTrace2U32", "nimFwMgmtFcTrace"]:
        source = source.replace(procedure(source, name), "")
    source = source.replace("proc txFrameEnv", "proc observe(label: string)\nproc txFrameEnv", 1)
    source += r"""
proc hostTxInternalLinkNodeAt(p: pointer): ptr LinkDesc = hostTxLinkDescAt(p)
proc txBackupQueueTailPtr(ac: uint32): ptr pointer = addr tails[ac]
proc vifChannelForIdx(index: uint8): ptr TxVif =
  doAssert index < 2
  addr vifs[index]
proc vifChannelAt(p: pointer): ptr TxVif = cast[ptr TxVif](p)
proc chanEnvView(): ptr ChannelEnv = addr channel
proc chanCtxtAt(p: ptr ChannelContext): ptr ChannelContext = p
proc nimFwMgmtFcTrace(fc: uint8): bool = (fc and 12) == 0
proc nimFwTrace2U32(s: string; a, b: uint32) = observe(s)
proc nimFwConnectTrace2U32(s: string; a, b: uint32) = observe(s)
proc nimFwConnectTraceBytes(s: string; p: pointer; size, limit: uint32) = observe(s)
proc txl_cntrl_tx_check(p: pointer): bool =
  result = profile in [0, 2, 4]
  observe("ready")
proc chan_is_on_channel(p: pointer): bool =
  result = true
  observe("on-channel")
proc apm_tx_int_ps_check(p: pointer): bool =
  result = profile != 2
  observe("ps-check")
proc macTimeNow(): uint32 =
  result = 0x12345678
  observe("time")
proc txl_payload_handle_backup(p: pointer)
proc apm_tx_int_ps_postpone(p, sta: pointer)
"""
    return source


CHECKS = r"""
proc reuseFrame() =
  let before = watching
  watching = false
  txl_frame_release(held[0], false)
  replacementFrame = hostTxDescAt(txl_frame_get(24))
  doAssert replacementFrame == held[0]
  replacementFrame.vifIdx = 0
  replacementFrame.staInfoIdx = 0
  replacementFrame.staIdx = 4
  replacementFrame.pendingMacTime = 0xFEED1234'u32
  hostTxHwDescAt(replacementFrame.hwDesc).controlFlags = 0x1234ABCD
  hostTxLinkDescAt(replacementFrame.bufDesc).headerThd.magic = 0x76543210
  replacementSnapshot = replacementFrame[]
  replacementHardware = hostTxHwDescAt(replacementFrame.hwDesc)[]
  replacementLink = hostTxLinkDescAt(replacementFrame.bufDesc)[]
  watching = before

proc observe(label: string) =
  if not watching: return
  doAssert not interruptsEnabled, "preparation escaped its IRQ scope"
  doAssert drainCalls == 0 and postponeCalls == 0, "descriptor trace after handoff"
  doAssert txEnv.packetCounter == 0 and frameEnv.postponedCount == 0
  for ac in 0 .. 4:
    doAssert backups[ac] == nil and acs[ac].pending.first == nil,
      "callout observed partial publication"
  inc step
  if fired or stopAt == 0 or step != stopAt: return
  fired = true
  case change
  of 0: inc rxVifEpochs[1]
  of 1: inc stationEpochs[1]
  of 2: reuseFrame()
  else: inc rxVifEpochs[0]

proc txl_payload_handle_backup(p: pointer) =
  inc drainCalls
  doAssert interruptsEnabled == incomingIrq and drainCalls == 1
  doAssert txEnv.packetCounter == 1
  doAssert backups[selectedAc] == held[0].bufDesc
  doAssert tails[selectedAc] == held[0].bufDesc
  doAssert acs[selectedAc].pending.first == addr held[0].link
  doAssert acs[selectedAc].pending.last == addr held[0].link
  doAssert hostTxHwDescAt(held[0].hwDesc).controlFlags == 0x100
  let link = hostTxLinkDescAt(held[0].bufDesc)
  doAssert link.headerThd.magic == 0xCAFEFADE'u32 and link.txDesc == held[0]
  if drainReuse:
    discard co_list_pop_front(addr acs[selectedAc].pending)
    backups[selectedAc] = nil
    tails[selectedAc] = nil
    dec txEnv.packetCounter
    reuseFrame()

proc apm_tx_int_ps_postpone(p, sta: pointer) =
  inc postponeCalls
  doAssert not interruptsEnabled and postponeCalls == 1
  doAssert frameEnv.postponedCount == 1, "postpone notification precedes accounting"
  doAssert stas[1].postponedList.first == addr held[0].link
  doAssert held[0].staIdx == selectedAc.uint8 and held[0].postponeFlag == 1
  if drainReuse:
    discard co_list_pop_front(addr stas[1].postponedList)
    dec frameEnv.postponedCount
    reuseFrame()

proc initialize(caseProfile, ac: int) =
  watching = false
  interruptsEnabled = true
  incomingIrq = true
  setup()
  for i in 0 .. 3:
    held[i] = hostTxDescAt(txl_frame_get(24))
    held[i].vifIdx = 1
    held[i].staInfoIdx = 1
    held[i].staIdx = ac.uint8
    hostTxLinkDescAt(held[i].bufDesc).macHeader[0] = 0xB0
  if caseProfile == 3: held[0].staInfoIdx = 255
  if caseProfile >= 4:
    let link = hostTxLinkDescAt(held[0].bufDesc)
    link.macHeader[0] = 0x48
    link.macHeader[1] = 0x01
  if caseProfile == 5: held[0].pendingMacTime = 42
  vifs[0] = TxVif(vifIdx: 0, chanCtxt: addr context)
  vifs[1] = TxVif(vifIdx: 1, chanCtxt: addr context)
  channel = ChannelEnv(currentCtxt: addr context, scheduledCtxt: addr context)
  tails = default(typeof(tails))
  replacementFrame = nil
  step = 0
  fired = false
  drainCalls = 0
  postponeCalls = 0
  profile = caseProfile
  selectedAc = ac
  drainReuse = false
  watching = true

proc checkReplacement() =
  doAssert replacementFrame != nil
  doAssert replacementFrame[] == replacementSnapshot, "replacement descriptor overwritten"
  doAssert hostTxHwDescAt(replacementFrame.hwDesc)[] == replacementHardware
  doAssert hostTxLinkDescAt(replacementFrame.bufDesc)[] == replacementLink
  doAssert frameEnv.freeList.first == nil, "replacement lease freed"

for ac in 0 .. 4:
  for kind in 0 .. 5:
    initialize(kind, ac)
    stopAt = 0
    discard txl_cntrl_push_int(held[0], ac.uint8)
    let callouts = step
    doAssert callouts > 0 and interruptsEnabled
    for target in 1 .. callouts:
      for action in 0 .. 3:
        initialize(kind, ac)
        stopAt = target
        change = action
        let accepted = txl_cntrl_push_int(held[0], ac.uint8)
        doAssert fired and interruptsEnabled
        if action in [0, 1, 2]:
          doAssert accepted == 0 and drainCalls == 0 and postponeCalls == 0
          doAssert txEnv.packetCounter == 0 and frameEnv.postponedCount == 0
          if action == 2: checkReplacement()
          else: doAssert co_list_cnt(addr frameEnv.freeList) == 1
        elif kind in [0, 4]:
          doAssert accepted == 1 and drainCalls == 1
        elif kind in [1, 2, 5]:
          doAssert accepted == 1 and postponeCalls == 1
          doAssert held[0].pendingMacTime == (if kind == 5: 42'u32 else: 0x12345678'u32)
        else:
          doAssert accepted == 0 and co_list_cnt(addr frameEnv.freeList) == 1

# Both handoff paths may retire and reuse the descriptor before returning.
for ac in 0 .. 4:
  for kind in [0, 1, 2, 4, 5]:
    initialize(kind, ac)
    stopAt = 0
    drainReuse = true
    doAssert txl_cntrl_push_int(held[0], ac.uint8) == 1
    doAssert interruptsEnabled and txEnv.packetCounter == 0 and frameEnv.postponedCount == 0
    checkReplacement()
  initialize(0, ac)
  stopAt = 0
  drainReuse = true
  doAssert txl_cntrl_push_int_force(held[0], ac.uint8) == 1
  doAssert interruptsEnabled and txEnv.packetCounter == 0
  checkReplacement()

# Nested callers retain their incoming interrupt-disabled state.
for force in [false, true]:
  initialize(0, 2)
  stopAt = 0
  interruptsEnabled = false
  incomingIrq = false
  let accepted = if force: txl_cntrl_push_int_force(held[0], 2)
                 else: txl_cntrl_push_int(held[0], 2)
  doAssert accepted == 1 and not interruptsEnabled

# Invalid ACs cannot index queues or lose the caller-held frame.
for ac in [5'u8, 31, 255]:
  for force in [false, true]:
    initialize(0, 0)
    stopAt = 0
    let accepted = if force: txl_cntrl_push_int_force(held[0], ac)
                   else: txl_cntrl_push_int(held[0], ac)
    doAssert accepted == 0 and interruptsEnabled and drainCalls == 0
    doAssert co_list_cnt(addr frameEnv.freeList) == 1
doAssert txl_cntrl_push_int(nil, 0) == 0
doAssert txl_cntrl_push_int_force(nil, 0) == 0
"""


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
@pytest.mark.parametrize("mutation", [None, "checkpoints", "generation", "post_handoff", "postpone_count", "irq", "fake_callout"])
def test_internal_preparation(tmp_path: Path, mode: str, mutation: str | None) -> None:
    nim = shutil.which("nim")
    if nim is None:
        pytest.skip("Nim is required")
    tx = (FW / "tx_layer.nim").read_text()
    functions = "".join(procedure(tx, name) for name in [
        "txl_frame_desc_index", "txlCaptureFrameIdentity", "txlFrameBeginLease",
        "txlFrameEndLease", "txlFrameLeaseToken", "txlFrameLeaseMatches",
        "txlFrameIdentityCurrent", "txlFrameSessionCurrent", "txlCaptureFrameCallback",
        "txlFrameCallbackCurrent", "txlInvokeFrameCallback", "txlStationAdmits",
        "txlCaptureSession", "txlSessionCurrent", "txl_frame_free_list_pop", "txl_frame_get",
        "txl_frame_release",
    ])
    functions += procedure((FW / "task_handlers.nim").read_text(), "txl_int_fake_transfer")
    push = procedure(tx, "txl_cntrl_push_int")
    force = procedure(tx, "txl_cntrl_push_int_force")
    if mutation == "checkpoints":
        push, count = re.subn(r"(?m)^\s+ensureInternalPreparation\(\)\n", "\n", push)
        assert count == 20
    elif mutation == "generation":
        push = push.replace("    if not txlFrameLeaseMatches(desc, generation):\n      return 0'u8\n", "")
    elif mutation == "post_handoff":
        push = push.replace("      txl_payload_handle_backup(param)\n",
            "      txl_payload_handle_backup(param)\n      nimFwTrace2U32(\"late\", 0, pointerAddrU32(desc.hwDesc))\n")
    elif mutation == "postpone_count":
        old = "  frameEnv.postponedCount = frameEnv.postponedCount + 1\n  apm_tx_int_ps_postpone(param, staEntry)"
        assert old in push
        push = push.replace(old, "  apm_tx_int_ps_postpone(param, staEntry)\n  frameEnv.postponedCount = frameEnv.postponedCount + 1")
    elif mutation == "irq":
        push = push.replace("  let saved = irqSave()\n", "  let saved = 8'u32\n", 1)
    elif mutation == "fake_callout":
        functions = functions.replace("  # Publication must stay callback-free, as in the vendor's 52-byte helper.\n",
            "  nimFwTrace2U32(\"fake\", queueIdx, 0)\n")
    functions += push + force
    debug = "\nvar\n" + "".join(f"  {name}: uint32\n" for name in sorted(set(re.findall(r"\bnimFwDbg\w+", functions))))
    source = tmp_path / "internal_preparation.nim"
    source.write_text(platform_source() + debug + functions + CHECKS)
    options = {"checked": [], "release": ["-d:release", "--assertions:on"],
        "asan": ["--cc:clang", "--passC:-fsanitize=address", "--passL:-fsanitize=address"]}
    result = subprocess.run([nim, "c", "-r", "--skipParentCfg:on", "--skipProjCfg:on", "--skipUserCfg:on",
        "-d:bl808WifiConnectTrace", f"--nimcache:{tmp_path / 'cache'}", f"-o:{tmp_path / 'test'}",
        *options[mode], str(source)], cwd=ROOT, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=120)
    if mutation is None:
        assert result.returncode == 0, result.stdout
    else:
        assert result.returncode != 0 and "AssertionDefect" in result.stdout, result.stdout


def test_internal_publication_has_no_reentrant_gap() -> None:
    tx = (FW / "tx_layer.nim").read_text()
    for name in ["txl_cntrl_push_int", "txl_cntrl_push_int_force"]:
        body = procedure(tx, name)
        assert body.index("irqSave()") < body.index("txlStationAdmits(desc)")
        assert body.count("irqRestore(saved)") == 2
        assert "if irqHeld: irqRestore(saved)" in body
        assert body.index("txCtrl.packetCounter = txCtrl.packetCounter + 1") < body.index("txl_payload_handle_backup(param)")
        indent = "  " if name.endswith("force") else "      "
        handoff = f"{indent}irqHeld = false\n{indent}irqRestore(saved)\n{indent}txl_payload_handle_backup(param)"
        assert body.index(handoff) > body.index("txCtrl.packetCounter = txCtrl.packetCounter + 1")
        tail = body.split("txl_payload_handle_backup(param)", 1)[1]
        tail = "\n".join(line.split("#", 1)[0] for line in tail.splitlines()).split("return 1'u8", 1)[0]
        assert re.search(r"\bdesc\.|\brcStats\b|nimFw.*Trace", tail) is None
    body = procedure(tx, "txl_cntrl_push_int")
    assert body.index("frameEnv.postponedCount = frameEnv.postponedCount + 1") < body.index("apm_tx_int_ps_postpone(param, staEntry)")
    fake = procedure((FW / "task_handlers.nim").read_text(), "txl_int_fake_transfer")
    for forbidden in ["nimFwTrace", "nimFwConnectTrace", "getLogFunc(", "blOpsFunc("]:
        assert forbidden not in fake
