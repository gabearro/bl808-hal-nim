"""Keep host TX completion accounting and IPC publication indivisible."""

from pathlib import Path
import re
import shutil
import subprocess

import pytest

from test_wifi_disconnect_tx import FW, ROOT, procedure
from test_wifi_tx_completion import PLATFORM as COMPLETION_PLATFORM


def platform_source() -> str:
    source = COMPLETION_PLATFORM
    for name in ["me_tx_cfm_singleton", "ipc_emb_txcfm", "irqRestore"]:
        source = source.replace(procedure(source, name), "")
    return source + r"""
type
  IpcHostTxWrapperView = object
    link: CoListHdr
    active: uint32
    txDesc: HostTxDescView
  IpcEnv = object
    hostTxCfmList: ptr CoList
const MAX_VIFS = 2
var
  wrappers: array[3, IpcHostTxWrapperView]
  hardware: array[3, HwDesc]
  heads: array[3, HeadThd]
  outputs: array[3, uint32]
  published: CoList
  ipc: IpcEnv
  stationAttempts: array[7, uint32]
  txResetEpoch: uint32
  rxVifEpochs: array[MAX_VIFS, uint32]
  staDeleteEpochs: array[7, uint32]
  rateIrqs: seq[bool]
  onRestore, onStore: proc()
  consumed: seq[int]
proc irqRestore(saved: uint32) =
  interruptsEnabled = (saved and 8) != 0
  if interruptsEnabled and onRestore != nil: onRestore()
proc txSecurityForget(d: pointer) = discard
proc ipcEmbEnvView(): ptr IpcEnv = addr ipc
proc ipcHostTxWrapperFromDesc(d: ptr HostTxDescView): ptr IpcHostTxWrapperView =
  for i in 0 ..< wrappers.len:
    if d == addr wrappers[i].txDesc: return addr wrappers[i]
  doAssert false, "unknown host wrapper"
proc loadPtr(p: pointer; offset: uint): pointer =
  cast[ptr pointer](cast[uint](p) + (offset div 4) * sizeof(pointer).uint)[]
proc storePtr(p: pointer; offset: uint; value: pointer) =
  cast[ptr pointer](cast[uint](p) + (offset div 4) * sizeof(pointer).uint)[] = value
  if onStore != nil: onStore()
type
  UtilsList = CoList
  UtilsListHdr = CoListHdr
proc rf_dump_status() = discard
proc staDeleteEpoch(index: uint8): uint32 = staDeleteEpochs[index]
proc rc_update_counters(station: uint8; attempts, failures: uint32;
                        aggregate, retry: bool) =
  doAssert station < 7
  stationAttempts[station] += attempts
  rateIrqs.add(interruptsEnabled)
"""


CHECKS = r"""
proc setup() =
  onRestore = nil
  onStore = nil
  interruptsEnabled = true
  frameEnv = default(TxFrameEnvView)
  confirmLists = default(typeof(confirmLists))
  wrappers = default(typeof(wrappers))
  hardware = default(typeof(hardware))
  heads = default(typeof(heads))
  outputs = default(typeof(outputs))
  published = default(CoList)
  ipc.hostTxCfmList = addr published
  ke_env = default(typeof(ke_env))
  txEnv.packetCounter = 0
  stationAttempts = default(typeof(stationAttempts))
  txResetEpoch = 0
  rxVifEpochs = default(typeof(rxVifEpochs))
  staDeleteEpochs = default(typeof(staDeleteEpochs))
  rateIrqs.setLen(0)
  consumed.setLen(0)
  indications.setLen(0)
  for i in 0 ..< wrappers.len:
    wrappers[i].active = 1
    wrappers[i].txDesc = HostTxDescView(hwDesc: addr hardware[i],
      cfmDst: addr outputs[i], queueFirst: cast[pointer](1),
      staInfoIdx: i.uint8, active: 1)
    hardware[i].head = addr heads[i]
    heads[i].flags = 0x80800200'u32

proc drainPublished() =
  onStore = nil
  while published.first != nil:
    let node = utils_list_pop_front(addr published)
    var index = -1
    for i in 0 ..< wrappers.len:
      if node == addr wrappers[i].link: index = i
    doAssert index >= 0
    doAssert index notin consumed, "duplicate host completion"
    consumed.add(index)
    # Once the host receives the wrapper, it may reuse all of its fields.
    wrappers[index].txDesc = default(HostTxDescView)
  doAssert published.last == nil, "completion list has an orphan tail"

# The first unmasked boundary must have an active flush owner. A host observer
# at publication must see packet accounting already complete.
for ac in 0'u8 .. 4:
  for station in 0'u8 .. 1:
    for status in [0x80800200'u32, 0x81000100'u32]:
      setup()
      let frame = addr wrappers[0].txDesc
      frame.staInfoIdx = station
      heads[0].flags = status
      txEnv.packetCounter = 1
      ke_env[0] = txl_cfm_evt_bit[ac] or 0x1000
      co_list_push_back(addr confirmLists[ac], addr frame.link)
      var changed = false
      onRestore = proc() =
        if changed or confirmLists[ac].first != nil: return
        doAssert txActiveFlush != nil, "unowned completion at IRQ restore"
        if published.first != addr wrappers[0].link: return
        changed = true
        onRestore = nil
        txEnv.packetCounter = 7
      txl_cfm_evt(ac)
      onRestore = nil
      doAssert changed
      doAssert stationAttempts[station] == ((status shr 8) and 0xFF'u32) + 1
      doAssert txEnv.packetCounter == 7,
        "old completion consumed post-publication packet accounting"
      doAssert rateIrqs == @[true]
      doAssert outputs[0] == (status or 1)
      doAssert heads[0].confirmType == 0x101
      doAssert published.first == addr wrappers[0].link
      doAssert published.last == addr wrappers[0].link
      doAssert ke_env[0] == 0x1000
      doAssert indications == @[(1'u32 shl ac)]

# An IPC interrupt may consume earlier completions while another append is
# underway. Deliver it at every pointer store in the real list implementation.
for nonempty in [false, true]:
  for boundary in 1 .. 3:
    for enabled in [false, true]:
      setup()
      if nonempty: ipc_emb_txcfm(addr wrappers[0].txDesc)
      var stores = 0
      var pending = false
      var delivered = false
      onRestore = proc() =
        if not pending or delivered: return
        delivered = true
        onRestore = nil
        drainPublished()
      onStore = proc() =
        inc stores
        if stores != boundary: return
        pending = true
        if interruptsEnabled and not delivered:
          delivered = true
          onRestore = nil
          drainPublished()
      interruptsEnabled = enabled
      ipc_emb_txcfm(addr wrappers[1].txDesc)
      doAssert interruptsEnabled == enabled
      onStore = nil
      onRestore = nil
      # Model the normal confirmation notification after publication as well.
      drainPublished()
      doAssert consumed == (if nonempty: @[0, 1] else: @[1])
      doAssert published.first == nil and published.last == nil

# With interrupts already disabled, the event must leave them disabled.
for ac in 0'u8 .. 4:
  setup()
  let frame = addr wrappers[0].txDesc
  txEnv.packetCounter = 1
  ke_env[0] = txl_cfm_evt_bit[ac]
  co_list_push_back(addr confirmLists[ac], addr frame.link)
  interruptsEnabled = false
  txl_cfm_evt(ac)
  doAssert not interruptsEnabled and txEnv.packetCounter == 0
  doAssert rateIrqs == @[false] and stationAttempts[0] == 3
  drainPublished()
"""


def program(mutation: str | None) -> str:
    tx = (FW / "tx_layer.nim").read_text()
    ipc = (FW / "ipc_embedded.nim").read_text()
    me = (FW / "scan_station_ap_me.nim").read_text()
    lists = (ROOT / "src/bl808/wifi/support/utils_facade_parts/list_core.nim").read_text()
    functions = "".join(procedure(lists, name) for name in [
        "utils_list_push_back", "utils_list_pop_front"])
    functions += procedure(ipc, "ipc_emb_txcfm")
    functions += procedure(me, "me_tx_cfm_singleton")
    functions += procedure(tx, "txlCfmPending") + procedure(tx, "txl_cfm_evt")
    functions += procedure((FW / "tx_upper.nim").read_text(), "txu_cntrl_cfm")
    if mutation == "dequeue":
        target = "      let node = cast[ptr CoListHdr](co_list_pop_front(acList))\n"
        assert functions.count(target) == 1
        functions = functions.replace(target, target + "      irqRestore(irqState)\n")
    elif mutation == "accounting":
        target = "          txCtrl.packetCounter = txCtrl.packetCounter - 1\n"
        marker = "    if trace.enabled:\n"
        assert functions.count(target) == 1 and functions.count(marker) == 1
        functions = functions.replace(target, "").replace(
            marker, "    txCtrl.packetCounter = txCtrl.packetCounter - 1\n" + marker)
    elif mutation == "publication":
        begin = functions.index("proc ipc_emb_txcfm")
        end = functions.index("proc me_tx_cfm_singleton", begin)
        block = functions[begin:end]
        assert "  let saved = irqSave()\n" in block
        block = block.replace("  let saved = irqSave()\n", "  let saved = 0'u32\n")
        functions = functions[:begin] + block + functions[end:]
    debug = "\nvar\n" + "".join(
        f"  {name}: uint32\n" for name in sorted(set(re.findall(r"\bnimFwDbg\w+", functions)))
    )
    return platform_source() + debug + "\nproc txu_cntrl_cfm*(param: pointer) {.exportc, cdecl.}\n" + functions + CHECKS


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
@pytest.mark.parametrize("mutation", [None, "dequeue", "accounting", "publication"])
def test_host_completion_owner(tmp_path: Path, mode: str, mutation: str | None) -> None:
    nim = shutil.which("nim")
    if nim is None:
        pytest.skip("Nim is required")
    path = tmp_path / "host_completion.nim"
    path.write_text(program(mutation))
    command = [nim, "c", "-r", "--skipParentCfg:on", "--skipProjCfg:on", "--skipUserCfg:on"]
    if mode == "release": command += ["-d:release"]
    if mode == "asan": command += ["--passC:-fsanitize=address", "--passL:-fsanitize=address"]
    command += ["--checks:on", f"--nimcache:{tmp_path / 'cache'}", f"-o:{tmp_path / 'test'}", str(path)]
    result = subprocess.run(command, cwd=ROOT, text=True, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, timeout=90)
    if mutation is None:
        assert result.returncode == 0, result.stdout
    else:
        assert result.returncode != 0 and "AssertionDefect" in result.stdout, result.stdout
