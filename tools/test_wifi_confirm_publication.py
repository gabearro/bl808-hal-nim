"""Keep TX diagnostics outside descriptor ownership and publication windows."""

from pathlib import Path
import re
import shutil
import subprocess

import pytest

from test_wifi_disconnect_tx import procedure
from test_wifi_frame_allocation import PLATFORM as ALLOCATION_PLATFORM

ROOT = Path(__file__).resolve().parents[1]
FW = ROOT / "src/bl808/wifi/fw"


def platform_source() -> str:
    source = ALLOCATION_PLATFORM.replace(
        "    pendingMacTime: uint32",
        "    cfmDst: pointer\n    active: uint32\n    frameLen: uint16\n    pendingMacTime: uint32",
    ).replace(
        "  HwDesc = object",
        "  HeadThd = object\n    flags: uint32\n    confirmType: uint16\n"
        "  HwDesc = object\n    head: ptr HeadThd\n    txConfirmDescPtr: uint32",
    ).replace(
        "  interruptsEnabled = true",
        "  watchPublication = false\n  callout: proc(stage: string)\n  interruptsEnabled = true",
        1,
    )
    old = procedure(source, "irqRestore")
    source = source.replace(old, r"""
proc irqRestore(previous: uint32) =
  interruptsEnabled = (previous and 8) != 0
  if interruptsEnabled and callout != nil: callout("restore")
""")
    old = procedure(source, "co_list_push_back")
    source = source.replace(old, old.replace("  var present = list.first", """
  if watchPublication and list != addr frameEnv.freeList:
    doAssert not interruptsEnabled, "confirmation publication was interruptible"
  var present = list.first"""))
    source = source.replace(
        "proc nimFwTrace2U32(s: string; a, b: uint32) = discard",
        "proc nimFwTrace2U32(s: string; a, b: uint32)",
    )
    return source + r"""
type LogEntry = tuple[label: string, a, b: uint32]
var
  heads: array[4, HeadThd]
  confirmLists: array[5, CoList]
  txEnv: tuple[packetCounter: uint32]
  ke_env: array[4, uint32]
  txl_cfm_evt_bit = [0x4000'u32, 0x8000'u32, 0x10000'u32, 0x20000'u32, 0x40000'u32]
  logs: seq[LogEntry]
  callbacks, rateCalls, hostCalls, indications: int
  incoming: bool
  expectedDesc: ptr HostTxDescView
  expectedOutput: uint32

proc nimFwTrace2U32(s: string; a, b: uint32) =
  if not watchPublication: return
  logs.add((s, a, b))
  if callout != nil: callout(s)
proc nimFwConnectTrace2U32(s: string; a, b: uint32) = nimFwTrace2U32(s, a, b)
proc nimFwMgmtFcTrace(fc: uint8): bool = fc in [0'u8, 0xB0]
proc hostTxHeadThd(hw: ptr HwDesc): ptr HeadThd = hw.head
proc hostTxThdConfirmAt(head: ptr HeadThd): ptr HeadThd = head
proc hostTxConfirmLinkWord(desc: ptr HostTxDescView): ptr uint32 = addr desc.active
proc txCfmList(ac: uint32): ptr CoList = addr confirmLists[ac]
proc txControlEnv(): ptr tuple[packetCounter: uint32] = addr txEnv
proc ke_evt_set(bits: uint32) =
  doAssert not interruptsEnabled
  ke_env[0] = ke_env[0] or bits
proc ke_evt_clear(bits: uint32) = ke_env[0] = ke_env[0] and not bits
proc assert_err(condition, file: cstring; line: int) = doAssert false
proc sta_mgmt_aging_postponed_desc(sta: pointer; maxCount: uint32): uint32 = 0
proc completed(arg: pointer; status: uint32) {.cdecl.} =
  doAssert arg == expectedDesc and status == 0x11223344
  doAssert interruptsEnabled == incoming
  inc callbacks
proc me_tx_cfm_singleton(p: pointer) =
  doAssert p == expectedDesc and interruptsEnabled == incoming
  doAssert hostTxDescAt(p).active == 1
  inc rateCalls
proc txl_frame_release*(param: pointer; doCallback: bool) {.exportc, cdecl.}
proc ipc_emb_txcfm(p: pointer) =
  doAssert p == expectedDesc and expectedOutput == 0x81001235'u32
  doAssert hostTxDescAt(p).active == 0 and txEnv.packetCounter == 0
  doAssert hostTxHeadThd(hostTxHwDescAt(hostTxDescAt(p).hwDesc)).confirmType == 0x101
  inc hostCalls
  # The host allocator owns this release in production. Use the real private
  # allocator here so the old address can be reused during the next logger.
  hostTxDescAt(p).usedFlag = 0
  txl_frame_release(p, false)
proc ipc_emb_txcfm_ind(mask: uint32) =
  doAssert mask == 1 or mask == 2 or mask == 4 or mask == 8 or mask == 16
  inc indications
"""


CHECKS = r"""
var
  replacement: ptr HostTxDescView
  descSnapshot: HostTxDescView
  hwSnapshot: HwDesc
  linkSnapshot: LinkDesc
  replacementLink: LinkDesc
  armed: bool

proc replaceCompleted() =
  doAssert txEnv.packetCounter == 0
  doAssert frameEnv.usedList.first == nil
  for list in confirmLists: doAssert list.first == nil
  replacement = hostTxDescAt(txl_frame_get(26))
  doAssert replacement == expectedDesc, "completion did not release the old lease"
  replacement.callback = cast[pointer](0x55)
  replacement.callbackArg = cast[pointer](0x66)
  replacement.cfmDst = cast[pointer](0x77)
  replacement.queueFirst = cast[pointer](0x88)
  replacement.bufDesc = addr replacementLink
  replacement.active = 0xAABBCCDD'u32
  replacement.pendingMacTime = 0x12345678
  hostTxHwDescAt(replacement.hwDesc).confirmStatus = 0xDEADBEEF'u32
  hostTxHwDescAt(replacement.hwDesc).status = 0x88776655'u32
  hostTxHwDescAt(replacement.hwDesc).txConfirmDescPtr = 0x10203040
  heads[0].flags = 0x87654321'u32
  hostTxLinkDescAt(replacement.bufDesc).macHeader[0] = 0xFF
  descSnapshot = replacement[]
  hwSnapshot = hostTxHwDescAt(replacement.hwDesc)[]
  linkSnapshot = hostTxLinkDescAt(replacement.bufDesc)[]

for route in ["frame", "probe", "push", "event"]:
  for irq in [false, true]:
    for ac in 0'u8 .. 4'u8:
      for trigger in 0 .. 7:
        if trigger == 0 and (not irq or route == "event"): continue
        watchPublication = false
        callout = nil
        interruptsEnabled = true
        initPool()
        heads = default(typeof(heads))
        confirmLists = default(typeof(confirmLists))
        txEnv.packetCounter = 1
        ke_env = default(typeof(ke_env))
        ke_env[0] = 0x1000
        logs.setLen(0)
        callbacks = 0
        rateCalls = 0
        hostCalls = 0
        indications = 0
        nimFwDbgCfmTraceCount = 0
        replacement = nil
        expectedOutput = 0
        var held: array[4, ptr HostTxDescView]
        for i in 0 .. 3:
          held[i] = hostTxDescAt(txl_frame_get(24))
          doAssert held[i] != nil
          held[i].vifIdx = 0
          held[i].staInfoIdx = 0
        expectedDesc = held[0]
        let hw = hostTxHwDescAt(expectedDesc.hwDesc)
        let originalBuffer = pointerAddrU32(expectedDesc.bufDesc)
        hw.head = addr heads[0]
        hw.txConfirmDescPtr = 0x10008000
        hw.confirmStatus = 0x11223344
        hw.status = 0x1234
        heads[0].flags = 0x55667788
        let link = hostTxLinkDescAt(expectedDesc.bufDesc)
        link.macHeader[0] = if route == "probe": 0x40 else: 0xB0
        link.macHeader[1] = 0
        expectedDesc.callback = cast[pointer](completed)
        expectedDesc.callbackArg = expectedDesc
        expectedDesc.cfmDst = addr expectedOutput
        expectedDesc.active = 1
        if route == "push" or route == "event":
          expectedDesc.usedFlag = 1
          expectedDesc.queueFirst = cast[pointer](1)
        if route == "event":
          heads[0].flags = 0x81001234'u32
          co_list_push_back(addr confirmLists[ac], addr expectedDesc.link)
          ke_env[0] = ke_env[0] or txl_cfm_evt_bit[ac]
        incoming = irq
        interruptsEnabled = irq
        var logNumber = 0
        armed = true
        watchPublication = true
        callout = proc(stage: string) =
          if not armed: return
          let relevant = if trigger == 0: stage == "restore"
            elif route == "frame": stage.endsWith("frame_cfm ")
            elif route == "probe": stage.endsWith("probe_cfm ")
            elif route == "push": not stage.contains("cfm_evt") and stage != "restore"
            else: stage.contains("cfm_evt")
          if not relevant: return
          if trigger != 0:
            inc logNumber
            if logNumber != trigger: return
          armed = false
          if route == "frame" or route == "probe":
            doAssert frameEnv.usedList.first == addr expectedDesc.link
            doAssert (ke_env[0] and 0x80000) != 0
            txl_frame_evt()
          elif route == "push":
            doAssert confirmLists[ac].first == addr expectedDesc.link
            doAssert heads[0].flags == 0x81001234'u32
            doAssert (ke_env[0] and txl_cfm_evt_bit[ac]) != 0
            txl_cfm_evt(ac)
          replaceCompleted()
        if route == "frame" or route == "probe": txl_frame_cfm(expectedDesc)
        elif route == "push": txl_cfm_push(expectedDesc, 0x81001234'u32, ac.uint32)
        else: txl_cfm_evt(ac)
        callout = nil
        doAssert interruptsEnabled == irq
        if replacement == nil:
          if route == "frame" or route == "probe": txl_frame_evt()
          elif route == "push": txl_cfm_evt(ac)
        else:
          doAssert replacement[] == descSnapshot, "logger changed a replacement descriptor"
          doAssert hostTxHwDescAt(replacement.hwDesc)[] == hwSnapshot
          doAssert hostTxLinkDescAt(replacement.bufDesc)[] == linkSnapshot
          doAssert txlFrameLeaseMatches(replacement, txlFrameLeaseToken(replacement))
        let expectedLogs = if route == "frame": 2 elif route == "probe": 1 else: 7
        if trigger <= expectedLogs: doAssert replacement != nil
        doAssert txEnv.packetCounter == 0 and ke_env[0] == 0x1000
        doAssert callbacks == (if route in ["frame", "probe"]: 1 else: 0)
        doAssert hostCalls == (if route in ["push", "event"]: 1 else: 0)
        doAssert rateCalls == hostCalls and indications == hostCalls
        for entry in logs:
          if entry.label == "[WIFI-CT] frame_cfm " or entry.label == "[WIFI-SCAN] probe_cfm ":
            doAssert entry.a == 0x11223344 and entry.b == 0x1234
          elif entry.label == "[WIFI-NIMFW] cfm_links " or entry.label == "[WIFI-CT] cfm_links " or
              entry.label == "[WIFI-NIMFW] cfm_evt_lnk " or entry.label == "[WIFI-CT] cfm_evt_lnk ":
            doAssert entry.a == 1 and entry.b == originalBuffer
          elif entry.label == "[WIFI-CT] cfm_status ":
            doAssert entry.a == 0x55667788 and entry.b == 0x81001234'u32
          elif entry.label == "[WIFI-CT] cfm_evt_status ":
            doAssert entry.a == 0x81001234'u32 and entry.b == pointerAddrU32(addr expectedOutput)

# No trace threshold may suppress confirmation delivery, and a missing hardware
# descriptor must not cause the diagnostic-only path to dereference nil.
for count in [31'u32, 32, 63, 64]:
  for badHead in [false, true]:
    watchPublication = false
    callout = nil
    interruptsEnabled = true
    initPool()
    confirmLists = default(typeof(confirmLists))
    ke_env = default(typeof(ke_env))
    let desc = hostTxDescAt(txl_frame_get(24))
    hostTxHwDescAt(desc.hwDesc).head = addr heads[0]
    hostTxHwDescAt(desc.hwDesc).txConfirmDescPtr = if badHead: 0xBADCAB1E'u32 else: 0
    nimFwDbgCfmTraceCount = count
    logs.setLen(0)
    watchPublication = true
    txl_cfm_push(desc, 0x81001234'u32, 4)
    doAssert confirmLists[4].first == addr desc.link
    doAssert ke_env[0] == txl_cfm_evt_bit[4]
    doAssert logs.len == (if count < 32 or badHead: 7 else: 0)
watchPublication = false
initPool()
let missingHw = hostTxDescAt(txl_frame_get(24))
hostTxLinkDescAt(missingHw.bufDesc).macHeader[0] = 0xB0
missingHw.hwDesc = nil
txl_frame_cfm(missingHw)
doAssert frameEnv.usedList.first == addr missingHw.link
"""


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
@pytest.mark.parametrize("mutation", [None, "frame_order", "push_order", "event_order",
                                      "frame_live", "push_live", "event_live", "unlocked"])
def test_confirm_publication(tmp_path: Path, mode: str, mutation: str | None) -> None:
    nim = shutil.which("nim")
    if nim is None:
        pytest.skip("Nim is required")
    tx = (FW / "tx_layer.nim").read_text()
    functions = "".join(procedure(tx, name) for name in [
        "txl_frame_desc_index", "txlCaptureFrameIdentity", "txlFrameBeginLease",
        "txlFrameEndLease", "txlFrameLeaseToken", "txlFrameLeaseMatches",
        "txlFrameIdentityCurrent", "txlFrameSessionCurrent", "txlCaptureFrameCallback",
        "txlFrameCallbackCurrent", "txlInvokeFrameCallback", "txl_frame_free_list_pop",
        "txl_frame_get", "txl_frame_release", "noteMgmtTxConfirm", "txl_frame_cfm",
        "txlFrameConfirmPending", "txl_frame_evt", "txl_cfm_push", "txlCfmPending", "txl_cfm_evt",
    ])
    ack_bit = next(line for line in tx.splitlines() if line.startswith("const WifiTxFrameSuccessfulBit ="))
    functions = ack_bit + "\n" + functions
    if mutation and mutation.endswith("_order"):
        name = {"frame_order": "txl_frame_cfm", "push_order": "txl_cfm_push",
                "event_order": "txl_cfm_evt"}[mutation]
        body = procedure(functions, name)
        if mutation == "event_order":
            old = "            ipc_emb_txcfm(cast[pointer](node))\n"
            new = '            nimFwTrace2U32("[WIFI-NIMFW] cfm_evt ", 0, 0)\n' + old
        else:
            old = "    snapshot\n"
            label = "frame_cfm" if mutation == "frame_order" else "cfm_push"
            # The mutation recreates the original pre-publication callout.
            marker = "    co_list_push_back("
            pos = body.index(marker)
            body = body[:pos] + f'    nimFwTrace2U32("[WIFI-NIMFW] {label} ", 0, 0)\n' + body[pos:]
            new = old
        functions = functions.replace(procedure(functions, name), body.replace(old, new, 1))
    elif mutation and mutation.endswith("_live"):
        old, new = {
            "frame_live": ("trace.confirmStatus, trace.status)",
                           "hostTxHwDescAt(hostTxDescAt(param).hwDesc).confirmStatus, trace.status)"),
            "push_live": ("trace.queue, trace.buffer)", "trace.queue, pointerAddrU32(hostTxDescAt(desc).bufDesc))"),
            "event_live": ("trace.thdStatus, trace.destination)",
                           "hostTxHeadThd(hostTxHwDescAt(hostTxDescAt(cast[pointer](trace.node)).hwDesc)).flags, trace.destination)"),
        }[mutation]
        assert old in functions
        functions = functions.replace(old, new, 1)
    elif mutation == "unlocked":
        body = procedure(functions, "txl_frame_cfm")
        old = "    let saved = irqSave()\n    defer: irqRestore(saved)\n"
        assert old in body
        functions = functions.replace(body, body.replace(old, ""))
    functions = procedure((FW / "tx_upper.nim").read_text(), "txu_cntrl_cfm") + functions
    debug = "\nvar\n" + "".join(f"  {name}: uint32\n" for name in sorted(set(
        re.findall(r"\bnimFwDbg\w+", functions))))
    source = tmp_path / "confirm_publication.nim"
    source.write_text("import std/strutils\n" + platform_source() + debug + functions + CHECKS)
    options = {"checked": [], "release": ["-d:release", "--assertions:on"],
               "asan": ["--cc:clang", "--passC:-fsanitize=address", "--passL:-fsanitize=address"]}
    result = subprocess.run([nim, "c", "-r", "--skipParentCfg:on", "--skipProjCfg:on", "--skipUserCfg:on",
        "-d:bl808WifiConnectTrace", "-d:bl808WifiScanTrace", f"--nimcache:{tmp_path / 'cache'}",
        f"-o:{tmp_path / 'test'}", *options[mode], str(source)], cwd=ROOT, text=True,
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=120)
    if mutation is None:
        assert result.returncode == 0, result.stdout
    else:
        assert result.returncode != 0 and "AssertionDefect" in result.stdout, result.stdout
