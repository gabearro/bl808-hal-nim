"""Exercise station retirement through real TX flush/completion routines."""

from pathlib import Path
import re
import shutil
import subprocess

import pytest

from test_wifi_disconnect_tx import procedure
from test_wifi_tx_flush_lifetime import PLATFORM as TX_PLATFORM

ROOT = Path(__file__).resolve().parents[1]
FW = ROOT / "src/bl808/wifi/fw"

PLATFORM = TX_PLATFORM.replace(
    "    txConfirmDescPtr, status, confirmStatus: uint32",
    "    txConfirmDescPtr, status, confirmStatus, controlFlags: uint32",
).replace("    packetCounter: uint32\n", "    packetCounter: uint32\n    resetInProgress: uint8\n") + r"""
const
  MAX_VIFS = 2
  STA_MGMT_FREE_STAS = 5
  STA_INFO_TAB_ENTRIES = 7
  WifiHwPollLimit = 4'u32
type
  StaQueueIdentity = object
    entry: pointer
    stationEpoch, vifEpoch: uint32
    station, vif: uint8
    stationTracked, vifTracked: bool
  Sta = object
    link: CoListHdr
    instNbr, valid: uint8
    marker: uint32
    postponedList: CoList
  Vif = object
    stations: CoList
  IpcHostTxWrapperView = object
    link: CoListHdr
    active: uint32
    txDesc: HostTxDescView
var
  stations: array[7, Sta]
  vifs: array[2, Vif]
  sta_info_env: CoList
  epochs: array[5, uint32]
  rxVifEpochs: array[2, uint32]
  hostQueue: CoList
  ipc: tuple[hostTxList: ptr CoList]
  entryResets, fakeTransfers: int
  beforeEntryReset: proc(p: pointer)
proc staInfoForIdx(index: uint8): ptr Sta = addr stations[index]
proc staInfoAt(p: pointer): ptr Sta = cast[ptr Sta](p)
proc staDeleteEpoch(index: uint8): uint32 =
  if index < 5: epochs[index] else: 0
proc txlResetting(): bool = false
proc txSecurityCurrent(desc: ptr HostTxDescView; allowInternalNull = false): bool = true
proc noteHwWaitTimeout(address, mask: uint32) =
  doAssert false, "unexpected halt timeout"
proc hal_machw_disable_int() =
  doAssert false, "unexpected MAC recovery"
proc txlVifIsRetiring(index: uint8): bool = false
proc vifChannelForIdx(index: uint8): ptr Vif = addr vifs[index]
proc vifPostponedStaList(vif: ptr Vif): ptr CoList = addr vif.stations
proc ipcEmbEnvView(): ptr typeof(ipc) = addr ipc
proc co_list_find(list: ptr CoList; node: ptr CoListHdr): bool =
  var current = list.first
  while current != nil:
    if current == node: return true
    current = current.next
proc co_list_extract(list: ptr CoList; node: ptr CoListHdr) =
  var previous: ptr CoListHdr
  var current = list.first
  while current != nil:
    if current == node:
      if previous == nil: list.first = current.next
      else: previous.next = current.next
      if list.last == current: list.last = previous
      current.next = nil
      return
    previous = current
    current = current.next
proc staDeleteInvalidate(index: uint8) = inc epochs[index]
proc staDeleteCancelQueued(index: uint8) = discard
proc staMgmtResetEntry(owner: StaQueueIdentity; requireRetired: bool): bool =
  let p = owner.entry
  let sta = cast[ptr Sta](p)
  doAssert requireRetired
  doAssert sta.valid == 0
  doAssert frameEnv.usedList.first == nil
  for ac in 0 .. 4:
    for queue in [confirmLists[ac], txEnv.ac[ac].pending]:
      var node = queue.first
      while node != nil:
        doAssert staInfoForIdx(hostTxDescAt(node).staInfoIdx) != sta
        node = node.next
  if beforeEntryReset != nil: beforeEntryReset(p)
  inc epochs[owner.station]
  inc entryResets
  zeroMem(sta, sizeof(Sta))
  sta.instNbr = 255
  true
proc txl_int_fake_transfer(p: pointer; ac: uint32) =
  inc fakeTransfers
  buffers.backupQueues[ac] = (p, p)
proc txl_payload_handle_backup(p: pointer) = discard
"""

CHECKS = r"""
var
  descriptors: array[7, HostTxDescView]
  hardware: array[7, HwDesc]
  thds: array[7, HeadThd]
  outputs: array[7, uint32]
  wrappers: array[3, IpcHostTxWrapperView]
  queueIndex, vifIndex: uint8
  callbacks: int

proc checkRetiring() =
  doAssert stations[2].valid == 0 and stations[2].marker == 1234
  doAssert entryResets == 0 and epochs[2] != 0
  doAssert not co_list_find(addr vifs[vifIndex].stations, addr stations[2].link)
  doAssert not co_list_find(addr sta_info_env, addr stations[2].link)
  sta_mgmt_unregister(2)
  doAssert entryResets == 0

proc completion(arg: pointer; status: uint32) {.cdecl.} =
  inc callbacks
  checkRetiring()
  # A callback must not put another descriptor on the retiring station.
  let before = txEnv.packetCounter
  doAssert txl_cntrl_push_int_force(addr descriptors[4], queueIndex) == 0
  doAssert txEnv.packetCounter == before
  # Independent work submitted by the same callback survives the old flush.
  doAssert txl_cntrl_push_int_force(addr descriptors[5], queueIndex) == 1

for vif in 0'u8 .. 1:
  for ac in 0'u8 .. 4:
    for root in 0 .. 2: # pending, confirmation, already-completed internal frame
      vifIndex = vif
      queueIndex = ac
      callbacks = 0
      entryResets = 0
      fakeTransfers = 0
      stations = default(typeof(stations))
      vifs = default(typeof(vifs))
      sta_info_env = default(CoList)
      frameEnv = default(TxFrameEnvView)
      txEnv = default(TxControlEnvView)
      confirmLists = default(typeof(confirmLists))
      buffers = default(BufferEnv)
      hostQueue = default(CoList)
      ipc.hostTxList = addr hostQueue
      wrappers = default(typeof(wrappers))
      descriptors = default(typeof(descriptors))
      hardware = default(typeof(hardware))
      thds = default(typeof(thds))
      outputs = default(typeof(outputs))
      hostCompletions.setLen(0)
      indications.setLen(0)
      interruptsEnabled = true
      active = 0x1F
      for id in [2, 3]:
        stations[id] = Sta(instNbr: vif, valid: 1, marker: 1234)
        co_list_push_back(addr vifs[vif].stations, addr stations[id].link)
      for i in 0 ..< descriptors.len:
        descriptors[i].hwDesc = addr hardware[i]
        descriptors[i].cfmDst = addr outputs[i]
        descriptors[i].vifIdx = vif
        descriptors[i].staInfoIdx = (if i in [0, 4]: 2'u8 else: 3'u8)
        hardware[i].head = addr thds[i]
      # The old target and the new independent frame are internal descriptors.
      descriptors[0].callback = cast[pointer](completion)
      for i in [1, 2]:
        descriptors[i].queueFirst = cast[pointer](1)
        descriptors[i].usedFlag = 1
      for i in 0 ..< wrappers.len:
        wrappers[i].active = (10 + i).uint32
        wrappers[i].txDesc.staInfoIdx = (if i == 1: 3'u8 else: 2'u8)
        co_list_push_back(addr hostQueue, addr wrappers[i].link)
      if root == 0:
        co_list_push_back(addr txEnv.ac[ac].pending, addr descriptors[0].link)
        txEnv.ac[ac].current = addr thds[0]
      elif root == 1:
        co_list_push_back(addr confirmLists[ac], addr descriptors[0].link)
      else:
        co_list_push_back(addr frameEnv.usedList, addr descriptors[0].link)
      co_list_push_back(addr txEnv.ac[ac].pending, addr descriptors[1].link)
      let otherAc = (ac + 1) mod 5
      co_list_push_back(addr txEnv.ac[otherAc].pending, addr descriptors[2].link)
      let backupFirst = if root == 0: 0 else: 1
      buffers.backupQueues[ac] = (cast[pointer](addr descriptors[backupFirst]),
                                 cast[pointer](addr descriptors[1]))
      txEnv.packetCounter = 3
      hostHook = proc(p: pointer) = checkRetiring()

      sta_mgmt_unregister(2)
      doAssert interruptsEnabled and callbacks == 1 and entryResets == 1
      doAssert stations[2].valid == 0 and stations[2].instNbr == 255
      doAssert sta_info_env.first == addr stations[2].link
      doAssert sta_info_env.last == addr stations[2].link
      doAssert stations[3].valid == 1 and vifs[vif].stations.first == addr stations[3].link
      doAssert wrappers[0].txDesc.staInfoIdx == 255 and wrappers[2].txDesc.staInfoIdx == 255
      doAssert wrappers[1].txDesc.staInfoIdx == 3
      doAssert hostQueue.first == (addr wrappers[0].link) and hostQueue.last == (addr wrappers[2].link)
      for i in 0 ..< wrappers.len: doAssert wrappers[i].active == (10 + i).uint32
      doAssert fakeTransfers == 1
      doAssert txEnv.ac[otherAc].pending.first == addr descriptors[2].link
      doAssert co_list_find(addr txEnv.ac[ac].pending, addr descriptors[5].link)
      if root != 2:
        doAssert hostCompletions == @[cast[pointer](addr descriptors[1])]
        doAssert txEnv.packetCounter == 2 # other AC plus callback submission
      else:
        doAssert hostCompletions.len == 0
        doAssert txEnv.packetCounter == 3 # no hardware AC belonged to target
      # Reusing the slot cannot revive queued host descriptors from its old life.
      stations[2] = Sta(instNbr: vif, valid: 1)
      doAssert wrappers[0].txDesc.staInfoIdx == 255 and wrappers[2].txDesc.staInfoIdx == 255

# Teardown also works before the host has provided its IPC queue.
ipc.hostTxList = nil
txEnv = default(TxControlEnvView)
frameEnv = default(TxFrameEnvView)
confirmLists = default(typeof(confirmLists))
vifs = default(typeof(vifs))
sta_info_env = default(CoList)
entryResets = 0
stations[2] = Sta(instNbr: 0, valid: 1)
co_list_push_back(addr vifs[0].stations, addr stations[2].link)
sta_mgmt_unregister(2)
doAssert entryResets == 1 and interruptsEnabled

# Exhaustive admission-index checks also run under ASan: no invalid table read.
for i in 0 ..< stations.len:
  stations[i].instNbr = (i mod 2).uint8
  stations[i].valid = (i mod 3 != 0).uint8
doAssert not txlStationAdmits(nil)
for vif in 0 .. 255:
  for id in 0 .. 255:
    var descriptor = HostTxDescView(vifIdx: vif.uint8, staInfoIdx: id.uint8)
    let expected = vif < 2 and (id == 255 or (id < 7 and
      stations[id].instNbr == vif.uint8 and (id >= 5 or stations[id].valid != 0)))
    doAssert txlStationAdmits(addr descriptor) == expected

# The hardware tail is not a software descriptor and may not be dereferenced
# to decide station ownership. An unrelated software chain must survive.
txEnv = default(TxControlEnvView)
confirmLists = default(typeof(confirmLists))
frameEnv = default(TxFrameEnvView)
hostHook = nil
ipc.hostTxList = nil
for ac in 0'u8 .. 4:
  var unrelated = HostTxDescView(staInfoIdx: 3)
  co_list_push_back(addr txEnv.ac[ac].pending, addr unrelated.link)
  txEnv.ac[ac].current = cast[pointer](1)
  txEnv.packetCounter = 1
  var selected: uint8
  doAssert txlHaltStationQueues(2, selected)
  txl_retire_station(2, selected)
  doAssert txEnv.packetCounter == 1
  doAssert txEnv.ac[ac].pending.first == addr unrelated.link
  doAssert txEnv.ac[ac].current == cast[pointer](1)
  co_list_init(addr txEnv.ac[ac].pending)
"""


NESTED_CHECKS = r"""
var
  frames: array[5, HostTxDescView]
  hardware: array[5, HwDesc]
  heads: array[5, HeadThd]
  outputs: array[5, uint32]
  completions: array[5, int]
  selectedVif: uint8

proc stationIndex(p: pointer): uint8 =
  for i in 0'u8 .. 6:
    if p == cast[pointer](addr stations[i]): return i
  doAssert false

proc beforeReset(p: pointer) =
  let index = stationIndex(p)
  doAssert completions[index] == 1,
    "station storage retired before its detached TX completion"
  doAssert stations[index].valid == 0 and stations[index].marker == 1234

proc onHost(p: pointer) =
  var index = -1
  for i in 0 .. 4:
    if p == cast[pointer](addr frames[i]): index = i
  doAssert index >= 0
  inc completions[index]
  doAssert completions[index] == 1, "duplicate completion"
  let station = index.uint8
  doAssert stations[station].valid == 0 and stations[station].marker == 1234,
    "old TX completed against a reused station"
  if station < 4:
    let next = station + 1
    sta_mgmt_unregister(next)
    doAssert completions[next] == 1
    doAssert co_list_pop_front(addr sta_info_env) == cast[pointer](addr stations[next])
    stations[next] = Sta(instNbr: selectedVif, valid: 1, marker: 9999)
    co_list_push_back(addr vifs[selectedVif].stations, addr stations[next].link)

for vif in 0'u8 .. 1:
  for ac in 0'u8 .. 4:
    for layout in 0 .. 3:
      selectedVif = vif
      stations = default(typeof(stations))
      vifs = default(typeof(vifs))
      sta_info_env = default(CoList)
      frameEnv = default(TxFrameEnvView)
      txEnv = default(TxControlEnvView)
      confirmLists = default(typeof(confirmLists))
      buffers = default(BufferEnv)
      frames = default(typeof(frames))
      hardware = default(typeof(hardware))
      heads = default(typeof(heads))
      outputs = default(typeof(outputs))
      completions = default(typeof(completions))
      hostCompletions.setLen(0)
      ipc.hostTxList = nil
      interruptsEnabled = true
      active = 0x1F
      entryResets = 0
      beforeEntryReset = beforeReset
      hostHook = onHost
      when declared(txActiveFlush): doAssert txActiveFlush == nil
      for i in 0 .. 4:
        let id = i.uint8
        stations[id] = Sta(instNbr: vif, valid: 1, marker: 1234)
        co_list_push_back(addr vifs[vif].stations, addr stations[id].link)
        frames[i] = HostTxDescView(staInfoIdx: id, vifIdx: vif,
          hwDesc: addr hardware[i], cfmDst: addr outputs[i],
          queueFirst: cast[pointer](1), usedFlag: 1)
        hardware[i].head = addr heads[i]
      if layout == 0:
        co_list_push_back(addr confirmLists[ac], addr frames[0].link)
        for i in 1 .. 4:
          co_list_push_back(addr txEnv.ac[ac].pending, addr frames[i].link)
      elif layout == 1:
        for frame in frames.mitems:
          co_list_push_back(addr txEnv.ac[ac].pending, addr frame.link)
      elif layout == 2:
        for frame in frames.mitems:
          co_list_push_back(addr confirmLists[ac], addr frame.link)
      else:
        # The deepest deletion must find an ancestor's detached batch,
        # while another AC has its own nested flush in progress.
        co_list_push_back(addr confirmLists[ac], addr frames[0].link)
        co_list_push_back(addr txEnv.ac[(ac + 1) mod 5].pending, addr frames[1].link)
        for i in 2 .. 4:
          co_list_push_back(addr txEnv.ac[ac].pending, addr frames[i].link)
      txEnv.packetCounter = 5
      sta_mgmt_unregister(0)
      doAssert interruptsEnabled and entryResets == 5
      doAssert completions == [1, 1, 1, 1, 1] and hostCompletions.len == 5
      doAssert txEnv.packetCounter == 0
      doAssert stations[0].valid == 0
      for i in 1 .. 4:
        doAssert stations[i].valid == 1 and stations[i].marker == 9999
      doAssert sta_info_env.first == addr stations[0].link
      doAssert sta_info_env.last == addr stations[0].link
      when declared(txActiveFlush): doAssert txActiveFlush == nil
"""


def run_program(tmp_path: Path, mode: str, checks: str) -> None:
    nim = shutil.which("nim")
    if nim is None:
        pytest.skip("Nim is required")
    tx = (FW / "tx_layer.nim").read_text()
    sta = (FW / "sta_management.nim").read_text()
    bodies = procedure((FW / "tx_upper.nim").read_text(), "txu_cntrl_cfm")
    for name in ["txlStationAdmits", "txl_frame_release", "txl_frame_cfm",
                 "txlFrameConfirmPending", "txl_frame_evt", "txl_cfm_flush",
                 "txl_cntrl_halt_ac", "txlDetachAc", "txl_cntrl_flush_ac", "txlQueueReferencesStation",
                 "txlDrainRetiredPostponed", "txlHaltStationQueues",
                 "txl_retire_station", "txl_cntrl_push_int_force"]:
        bodies += procedure(tx, name)
    for name in ["staPostponedOwner", "staPostponedOwnerCurrent", "staRemovalCurrent",
                 "staMgmtBeginRemoval", "staMgmtFinishRemoval", "sta_mgmt_unregister"]:
        bodies += procedure(sta, name)
    debug = "\nvar\n" + "".join(
        f"  {name}: uint32\n" for name in sorted(set(re.findall(r"\bnimFwDbg\w+", bodies)))
    )
    source = tmp_path / "station_tx.nim"
    source.write_text(PLATFORM + debug + bodies + checks)
    options = {"checked": [], "release": ["-d:release", "--assertions:on"],
               "asan": ["--cc:clang", "--passC:-fsanitize=address", "--passL:-fsanitize=address"]}
    result = subprocess.run([nim, "c", "-r", "--skipParentCfg:on", "--skipProjCfg:on",
        "--skipUserCfg:on", f"--nimcache:{tmp_path / 'cache'}", f"-o:{tmp_path / 'test'}",
        *options[mode], str(source)], cwd=ROOT, text=True,
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=90)
    assert result.returncode == 0, result.stdout


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_station_tx_drain(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, CHECKS)


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_nested_station_tx_drain(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, NESTED_CHECKS)
